#pragma once

#include <stddef.h>
#include <stdint.h>

typedef void (*p25_nid_callback_t)(uint16_t nac, uint8_t duid, uint32_t valid_count);
typedef void (*p25_control_callback_t)(uint16_t nac, uint32_t repeated_control_nids);

void p25_decoder_reset(void);
void p25_decoder_reset_stream(void);
void p25_decoder_set_callback(p25_nid_callback_t callback);
void p25_decoder_set_control_callback(p25_control_callback_t callback);
void p25_decoder_consume(const uint8_t *samples, size_t byte_count,
                         uint32_t center_hz, uint32_t sample_rate, uint32_t sequence);
uint32_t p25_decoder_valid_nids(void);
uint32_t p25_decoder_control_nids(void);
uint16_t p25_decoder_control_nac(void);
