#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t address;
    uint8_t downlink_format;
    uint8_t type_code;
    bool has_callsign;
    char callsign[9];
    bool has_altitude;
    int32_t altitude_ft;
    bool geometric_altitude;
} adsb_frame_t;

typedef void (*adsb_frame_callback_t)(const adsb_frame_t *frame);

void adsb_decoder_reset(void);
void adsb_decoder_reset_stream(void);
uint64_t adsb_decoder_valid_frames(void);
void adsb_decoder_set_callback(adsb_frame_callback_t callback);
void adsb_decoder_consume(const uint8_t *samples, size_t byte_count,
                          uint32_t center_hz, uint32_t sample_rate_sps,
                          uint32_t sequence);
