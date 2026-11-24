#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*tetra_candidate_callback_t)(uint32_t candidate_id, float strength_dbfs, bool new_candidate);

void tetra_detector_reset(void);
void tetra_detector_reset_stream(void);
void tetra_detector_set_callback(tetra_candidate_callback_t callback);
void tetra_detector_consume(const uint8_t *samples, size_t byte_count,
                            uint32_t center_hz, uint32_t sample_rate, uint32_t sequence);
uint32_t tetra_detector_candidate_count(void);
bool tetra_detector_active(void);
