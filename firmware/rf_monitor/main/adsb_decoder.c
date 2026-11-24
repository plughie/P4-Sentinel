#include "adsb_decoder.h"

#include <string.h>

enum {
    ADSB_RATE = 2048000,
    ADSB_CENTER_HZ = 1090000000,
    ENVELOPE_RING_SIZE = 512,
    FRAME_TAIL_SAMPLES = 246,
    LONG_FRAME_BITS = 112,
};

static uint16_t envelope[ENVELOPE_RING_SIZE];
static uint64_t sample_count;
static uint64_t valid_frames;
static uint64_t last_frame_sample;
static uint8_t last_frame[14];
static bool have_last_frame;
static adsb_frame_callback_t frame_callback;

static uint16_t magnitude(const uint8_t *iq)
{
    const int i = (int)iq[0] - 127;
    const int q = (int)iq[1] - 127;
    return (uint16_t)(i * i + q * q);
}

/* Sample the rolling envelope at a Q8 offset from a candidate preamble start. */
static uint16_t sample_at(uint64_t start, uint16_t offset_q8)
{
    const uint64_t lo = start + (offset_q8 >> 8);
    const int32_t fraction = offset_q8 & 0xff;
    const int32_t a = envelope[lo % ENVELOPE_RING_SIZE];
    const int32_t b = envelope[(lo + 1) % ENVELOPE_RING_SIZE];
    return (uint16_t)(a + ((b - a) * fraction) / 256);
}

static bool preamble_at(uint64_t start)
{
    static const uint16_t active_q8[] = {131, 655, 1966, 2490};
    static const uint16_t quiet_q8[] = {917, 1442, 1704, 2228, 2753, 3277, 3801};
    uint16_t min_active = UINT16_MAX;
    uint16_t max_quiet = 0;
    for (size_t i = 0; i < sizeof(active_q8) / sizeof(active_q8[0]); ++i) {
        const uint16_t value = sample_at(start, active_q8[i]);
        if (value < min_active) min_active = value;
    }
    for (size_t i = 0; i < sizeof(quiet_q8) / sizeof(quiet_q8[0]); ++i) {
        const uint16_t value = sample_at(start, quiet_q8[i]);
        if (value > max_quiet) max_quiet = value;
    }
    return (uint32_t)min_active * 100u > (uint32_t)max_quiet * 115u && min_active > 64;
}

static uint32_t bits(const uint8_t *frame, unsigned first, unsigned count)
{
    uint32_t value = 0;
    for (unsigned i = 0; i < count; ++i) {
        const unsigned index = first + i;
        value = (value << 1) | ((frame[index / 8] >> (7 - (index % 8))) & 1u);
    }
    return value;
}

static bool crc_valid(const uint8_t *frame)
{
    uint32_t remainder = 0;
    for (unsigned index = 0; index < LONG_FRAME_BITS; ++index) {
        const uint32_t bit = (frame[index / 8] >> (7 - (index % 8))) & 1u;
        const uint32_t feedback = ((remainder >> 23) & 1u) ^ bit;
        remainder = (remainder << 1) & 0xFFFFFFu;
        if (feedback) remainder ^= 0xFFF409u;
    }
    return remainder == 0;
}

static void decode_callsign(const uint8_t *frame, adsb_frame_t *decoded)
{
    size_t out = 0;
    for (unsigned i = 0; i < 8; ++i) {
        const uint32_t code = bits(frame, 40 + i * 6, 6);
        char character = '?';
        if (code == 32) character = ' ';
        else if (code >= 1 && code <= 26) character = (char)('A' + code - 1);
        else if (code >= 48 && code <= 57) character = (char)('0' + code - 48);
        if (character == '?') return;
        decoded->callsign[out++] = character;
    }
    while (out && decoded->callsign[out - 1] == ' ') --out;
    size_t first = 0;
    while (first < out && decoded->callsign[first] == ' ') ++first;
    if (first) {
        memmove(decoded->callsign, decoded->callsign + first, out - first);
        out -= first;
    }
    decoded->callsign[out] = '\0';
    decoded->has_callsign = out > 0;
}

static void decode_altitude(const uint8_t *frame, adsb_frame_t *decoded)
{
    const uint32_t encoded = bits(frame, 40, 12);
    if (encoded & 0x10u) {
        const uint32_t n = ((encoded & 0xFE0u) >> 1) | (encoded & 0xFu);
        decoded->altitude_ft = (int32_t)(25 * n) - 1000;
        decoded->has_altitude = true;
        decoded->geometric_altitude = decoded->type_code >= 20;
    }
}

static bool decode_frame(uint64_t start, uint8_t *frame, adsb_frame_t *decoded)
{
    memset(frame, 0, 14);
    for (unsigned bit = 0; bit < LONG_FRAME_BITS; ++bit) {
        const uint16_t bit_offset_q8 = (uint16_t)(4194u + bit * 524u);
        const uint16_t early = sample_at(start, (uint16_t)(bit_offset_q8 + 131u));
        const uint16_t late = sample_at(start, (uint16_t)(bit_offset_q8 + 393u));
        if (early > late) frame[bit / 8] |= (uint8_t)(1u << (7 - (bit % 8)));
    }

    const uint8_t df = frame[0] >> 3;
    if ((df != 17 && df != 18) || !crc_valid(frame)) return false;
    // DF18 CF=0 carries an ICAO address. Other control fields use different
    // address namespaces and are deliberately not folded into aircraft rows.
    if (df == 18 && (frame[0] & 0x07u) != 0) return false;

    memset(decoded, 0, sizeof(*decoded));
    decoded->downlink_format = df;
    decoded->address = ((uint32_t)frame[1] << 16) | ((uint32_t)frame[2] << 8) | frame[3];
    decoded->type_code = (uint8_t)bits(frame, 32, 5);
    if (decoded->type_code >= 1 && decoded->type_code <= 4) decode_callsign(frame, decoded);
    if ((decoded->type_code >= 9 && decoded->type_code <= 18)
        || (decoded->type_code >= 20 && decoded->type_code <= 22)) {
        decode_altitude(frame, decoded);
    }
    return true;
}

void adsb_decoder_set_callback(adsb_frame_callback_t callback)
{
    frame_callback = callback;
}

void adsb_decoder_reset_stream(void)
{
    memset(envelope, 0, sizeof(envelope));
    sample_count = 0;
    have_last_frame = false;
}

void adsb_decoder_reset(void)
{
    adsb_decoder_reset_stream();
    valid_frames = 0;
}

uint64_t adsb_decoder_valid_frames(void)
{
    return valid_frames;
}

void adsb_decoder_consume(const uint8_t *samples, size_t byte_count,
                          uint32_t center_hz, uint32_t sample_rate_sps,
                          uint32_t sequence)
{
    (void)sequence;
    if (!samples || center_hz != ADSB_CENTER_HZ || sample_rate_sps != ADSB_RATE) return;
    const size_t count = byte_count / 2;
    for (size_t i = 0; i < count; ++i) {
        envelope[sample_count % ENVELOPE_RING_SIZE] = magnitude(samples + i * 2);
        ++sample_count;
        if (sample_count <= FRAME_TAIL_SAMPLES) continue;
        const uint64_t start = sample_count - 1 - FRAME_TAIL_SAMPLES;
        if (!preamble_at(start)) continue;
        uint8_t frame[14];
        adsb_frame_t decoded;
        if (!decode_frame(start, frame, &decoded)) continue;
        if (have_last_frame && start - last_frame_sample < 260
            && memcmp(frame, last_frame, sizeof(last_frame)) == 0) continue;
        memcpy(last_frame, frame, sizeof(last_frame));
        last_frame_sample = start;
        have_last_frame = true;
        ++valid_frames;
        if (frame_callback) frame_callback(&decoded);
    }
}
