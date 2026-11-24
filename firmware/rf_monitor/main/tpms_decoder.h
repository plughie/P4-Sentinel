#pragma once

#include <stddef.h>
#include <stdint.h>

typedef void (*tpms_packet_callback_t)(uint32_t id, uint8_t flags,
                                       uint16_t pressure_hpa, int16_t temperature_c);

void tpms_decoder_reset(void);
void tpms_decoder_reset_stream(void);
void tpms_decoder_set_callback(tpms_packet_callback_t callback);
void tpms_decoder_consume(const uint8_t *samples, size_t byte_count,
                          uint32_t center_hz, uint32_t sample_rate, uint32_t sequence);
void tpms_decoder_consume_bits(const uint8_t *bits, size_t count);
uint32_t tpms_decoder_valid_packets(void);
