#pragma once

#include <stddef.h>
#include <stdint.h>

typedef void (*fm_audio_callback_t)(const int8_t *samples, size_t count);

void fm_audio_reset(void);
void fm_audio_set_callback(fm_audio_callback_t callback);
uint64_t fm_audio_input_samples(void);
uint64_t fm_audio_output_samples(void);
uint64_t fm_audio_emitted_blocks(void);
void fm_audio_consume(const uint8_t *samples, size_t byte_count, uint32_t center_hz,
                     uint32_t sample_rate, uint32_t sequence);
