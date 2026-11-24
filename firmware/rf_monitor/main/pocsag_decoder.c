#include "pocsag_decoder.h"

#include <math.h>
#include <stdbool.h>
#include <string.h>

enum { SAMPLE_RATE_HZ = 250000, BCH_POLY = 0x769, MAX_TEXT = 120 };
static const uint32_t sync_word = UINT32_C(0x7CD215D8);
static pocsag_address_callback_t address_callback;
static pocsag_message_callback_t message_callback;
static uint32_t shift_register, codeword, valid_words;
static uint32_t symbol_clock, codeword_bits, demod_samples;
static uint16_t baud_rate = 1200;
static double frequency_sum, frequency_baseline;
static float previous_i, previous_q;
static bool have_previous, waiting_words, inverted, active_page;
static uint8_t word_index, current_function;
static uint32_t current_capcode;
static char message_text[MAX_TEXT + 1];
static size_t message_length;
static uint32_t text_bits;
static uint8_t text_bit_count;

static unsigned bit_count32(uint32_t value)
{
    unsigned count = 0;
    while (value) { value &= value - 1; count++; }
    return count;
}

static uint16_t remainder31(uint32_t word)
{
    for (int bit = 30; bit >= 10; --bit) {
        if (word & (UINT32_C(1) << bit)) word ^= (uint32_t)BCH_POLY << (bit - 10);
    }
    return (uint16_t)(word & 0x3ff);
}

static bool valid_word(uint32_t word)
{
    return remainder31(word >> 1) == 0 && (bit_count32(word) & 1u) == 0;
}

static bool correct_word(uint32_t received, uint32_t *corrected)
{
    if (valid_word(received)) { *corrected = received; return true; }
    uint32_t candidate = 0;
    unsigned matches = 0;
    for (unsigned first = 0; first < 32; ++first) {
        const uint32_t one = received ^ (UINT32_C(1) << first);
        if (valid_word(one)) { candidate = one; matches++; }
        for (unsigned second = first + 1; second < 32; ++second) {
            const uint32_t two = one ^ (UINT32_C(1) << second);
            if (valid_word(two)) { candidate = two; matches++; }
        }
    }
    if (matches != 1) return false;
    *corrected = candidate;
    return true;
}

static void finish_message(void)
{
    if (active_page && message_length && message_callback) {
        message_text[message_length] = '\0';
        message_callback(current_capcode, current_function, message_text);
    }
    active_page = false;
    message_length = 0;
    text_bits = 0;
    text_bit_count = 0;
}

static void append_character(char value)
{
    if (message_length >= MAX_TEXT || value == '\0') return;
    message_text[message_length++] = value;
}

static void consume_word(uint32_t raw_word)
{
    uint32_t word;
    if (!correct_word(raw_word, &word)) return;
    valid_words++;
    if (word == UINT32_C(0x7A89C197)) return;

    const bool message_word = (word & UINT32_C(0x80000000)) != 0;
    if (!message_word) {
        finish_message();
        const uint8_t frame_number = word_index / 2;
        const uint32_t address18 = (word >> 13) & 0x3ffff;
        current_capcode = (address18 << 3) | frame_number;
        current_function = (word >> 11) & 0x03;
        active_page = true;
        if (address_callback) address_callback(current_capcode, current_function);
        return;
    }
    if (!active_page) return;

    const uint32_t payload = (word >> 11) & 0xfffff;
    if (current_function >= 2) {
        for (int bit = 19; bit >= 0; --bit) {
            text_bits |= ((payload >> bit) & 1u) << text_bit_count;
            if (++text_bit_count == 7) {
                const char character = (char)(text_bits & 0x7f);
                append_character(character >= 0x20 && character <= 0x7e ? character : ' ');
                text_bits = 0;
                text_bit_count = 0;
            }
        }
    } else {
        static const char digits[16] = {'0','1','2','3','4','5','6','7','8','9','*','U',' ','-',')','('};
        for (int shift = 16; shift >= 0; shift -= 4) append_character(digits[(payload >> shift) & 0x0f]);
    }
}

static void consume_bit(uint8_t bit)
{
    shift_register = (shift_register << 1) | (bit & 1u);
    if (!waiting_words) {
        if (shift_register == sync_word || shift_register == ~sync_word) {
            inverted = shift_register == ~sync_word;
            waiting_words = true;
            word_index = 0;
            codeword = 0;
            finish_message();
        }
        return;
    }
    const uint8_t decoded = inverted ? (uint8_t)(bit ^ 1u) : bit;
    codeword = (codeword << 1) | decoded;
    if (++codeword_bits == 32) {
        codeword_bits = 0;
        consume_word(codeword);
        codeword = 0;
        if (++word_index == 16) waiting_words = false;
    }
}

void pocsag_decoder_set_callbacks(pocsag_address_callback_t on_address,
                                  pocsag_message_callback_t on_message)
{
    address_callback = on_address;
    message_callback = on_message;
}

void pocsag_decoder_set_baud(uint16_t baud)
{
    if (baud == 512 || baud == 1200 || baud == 2400) baud_rate = baud;
}

void pocsag_decoder_reset_stream(void)
{
    shift_register = codeword = 0;
    symbol_clock = codeword_bits = demod_samples = 0;
    frequency_sum = 0;
    frequency_baseline = 0;
    previous_i = previous_q = 0;
    have_previous = false;
    waiting_words = inverted = false;
    word_index = 0;
}

void pocsag_decoder_reset(void)
{
    pocsag_decoder_reset_stream();
    finish_message();
    valid_words = 0;
}

void pocsag_decoder_finish(void) { finish_message(); }
uint32_t pocsag_decoder_valid_words(void) { return valid_words; }

void pocsag_decoder_consume_bits(const uint8_t *bits, size_t bit_count)
{
    if (!bits) return;
    for (size_t index = 0; index < bit_count; ++index) consume_bit(bits[index]);
}

void pocsag_decoder_consume(const uint8_t *samples, size_t byte_count,
                            uint32_t center_hz, uint32_t sample_rate, uint32_t sequence)
{
    (void)center_hz;
    (void)sequence;
    if (!samples || sample_rate != SAMPLE_RATE_HZ) return;
    for (size_t offset = 0; offset + 1 < byte_count; offset += 2) {
        const float i = (float)((int)samples[offset] - 127);
        const float q = (float)((int)samples[offset + 1] - 127);
        if (have_previous) {
            const double cross = (double)previous_i * q - (double)previous_q * i;
            const double dot = (double)previous_i * i + (double)previous_q * q;
            const double frequency = atan2(cross, dot) * (SAMPLE_RATE_HZ / 6.283185307179586);
            frequency_baseline += (frequency - frequency_baseline) * 0.00005;
            frequency_sum += frequency - frequency_baseline;
            demod_samples++;
        }
        previous_i = i;
        previous_q = q;
        have_previous = true;
        symbol_clock += baud_rate;
        if (symbol_clock >= SAMPLE_RATE_HZ) {
            symbol_clock -= SAMPLE_RATE_HZ;
            const double deviation = demod_samples ? frequency_sum / demod_samples : 0;
            demod_samples = 0;
            frequency_sum = 0;
            consume_bit(deviation >= 0 ? 1 : 0);
        }
    }
}
