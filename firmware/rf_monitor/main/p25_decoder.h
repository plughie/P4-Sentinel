#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef void (*p25_nid_callback_t)(uint16_t nac, uint8_t duid, uint32_t valid_count);
typedef void (*p25_control_callback_t)(uint16_t nac, uint32_t repeated_control_nids);
typedef void (*p25_tsbk_callback_t)(uint8_t opcode, uint8_t mfid, uint16_t nac,
                                    uint16_t channel, uint32_t frequency_hz,
                                    uint16_t talkgroup, bool last_block);

void p25_decoder_reset(void);
void p25_decoder_reset_stream(void);
void p25_decoder_set_callback(p25_nid_callback_t callback);
void p25_decoder_set_control_callback(p25_control_callback_t callback);
void p25_decoder_set_tsbk_callback(p25_tsbk_callback_t callback);
void p25_decoder_consume(const uint8_t *samples, size_t byte_count,
                         uint32_t center_hz, uint32_t sample_rate, uint32_t sequence);
uint32_t p25_decoder_valid_nids(void);
uint32_t p25_decoder_control_nids(void);
uint16_t p25_decoder_control_nac(void);
