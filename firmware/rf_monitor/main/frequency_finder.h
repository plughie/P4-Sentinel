#pragma once

#include <stdbool.h>
#include <stdint.h>

enum { FREQUENCY_FINDER_BINS = 512 };

typedef enum {
    FREQUENCY_FINDER_LEARNING,
    FREQUENCY_FINDER_ARMED,
    FREQUENCY_FINDER_CANDIDATE,
} frequency_finder_result_t;

typedef struct {
    uint32_t frequency_hz;
    uint16_t bin;
    float rise_db;
} frequency_finder_candidate_t;

void frequency_finder_reset(void);
frequency_finder_result_t frequency_finder_observe(const float power[FREQUENCY_FINDER_BINS],
                                                   uint32_t center_hz,
                                                   uint32_t sample_rate_hz,
                                                   frequency_finder_candidate_t *candidate);
bool frequency_finder_is_armed(void);
