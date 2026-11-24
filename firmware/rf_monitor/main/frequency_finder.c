#include "frequency_finder.h"

#include <math.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

enum {
    BASELINE_FRAMES = 64,
    FIRST_USABLE_BIN = 8,
    LAST_USABLE_BIN = FREQUENCY_FINDER_BINS - 8,
    CENTER_NOTCH_RADIUS = 3,
    MIN_RISE_TENTHS_DB = 90,
    REQUIRED_HITS = 2,
    MAX_BIN_STEP = 8,
};

static float baseline[FREQUENCY_FINDER_BINS];
static uint16_t baseline_frames;
static uint16_t hit_count;
static uint16_t previous_bin;
static bool candidate_reported;

void frequency_finder_reset(void)
{
    memset(baseline, 0, sizeof(baseline));
    baseline_frames = 0;
    hit_count = 0;
    previous_bin = 0;
    candidate_reported = false;
}

bool frequency_finder_is_armed(void)
{
    return baseline_frames >= BASELINE_FRAMES;
}

frequency_finder_result_t frequency_finder_observe(const float power[FREQUENCY_FINDER_BINS],
                                                   uint32_t center_hz,
                                                   uint32_t sample_rate_hz,
                                                   frequency_finder_candidate_t *candidate)
{
    if (!power || !sample_rate_hz) return FREQUENCY_FINDER_LEARNING;
    if (baseline_frames < BASELINE_FRAMES) {
        for (size_t bin = 0; bin < FREQUENCY_FINDER_BINS; ++bin)
            baseline[bin] += power[bin] / (float)BASELINE_FRAMES;
        baseline_frames++;
        return frequency_finder_is_armed() ? FREQUENCY_FINDER_ARMED : FREQUENCY_FINDER_LEARNING;
    }
    if (candidate_reported) return FREQUENCY_FINDER_ARMED;

    int best_margin_tenths_db = MIN_RISE_TENTHS_DB;
    uint16_t best_bin = 0;
    for (uint16_t bin = FIRST_USABLE_BIN; bin < LAST_USABLE_BIN; ++bin) {
        if (bin >= FREQUENCY_FINDER_BINS / 2 - CENTER_NOTCH_RADIUS
            && bin <= FREQUENCY_FINDER_BINS / 2 + CENTER_NOTCH_RADIUS) continue;
        const float floor = fmaxf(baseline[bin], 1.0e-12f);
        const float ratio = fmaxf(power[bin], 1.0e-12f) / floor;
        const int margin = (int)lroundf(100.0f * log10f(ratio));
        if (margin > best_margin_tenths_db) {
            best_margin_tenths_db = margin;
            best_bin = bin;
        }
    }

    if (!best_bin) {
        hit_count = 0;
        return FREQUENCY_FINDER_ARMED;
    }
    if (hit_count && abs((int)best_bin - (int)previous_bin) <= MAX_BIN_STEP) hit_count++;
    else hit_count = 1;
    previous_bin = best_bin;
    if (hit_count < REQUIRED_HITS) return FREQUENCY_FINDER_ARMED;

    const int32_t offset_bins = (int32_t)best_bin - (int32_t)(FREQUENCY_FINDER_BINS / 2);
    const int64_t offset_hz = (int64_t)offset_bins * sample_rate_hz / FREQUENCY_FINDER_BINS;
    const int64_t estimate_hz = (int64_t)center_hz + offset_hz;
    if (estimate_hz <= 0 || estimate_hz > UINT32_MAX) {
        hit_count = 0;
        return FREQUENCY_FINDER_ARMED;
    }
    if (candidate) {
        candidate->frequency_hz = (uint32_t)estimate_hz;
        candidate->bin = best_bin;
        candidate->rise_db = (float)best_margin_tenths_db / 10.0f;
    }
    candidate_reported = true;
    return FREQUENCY_FINDER_CANDIDATE;
}
