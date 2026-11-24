#include "tetra_detector.h"

#include <math.h>

enum { WINDOW_SAMPLES = 1000, WINDOWS_PER_UPDATE = 250, REQUIRED_HIGH_WINDOWS = 2, REQUIRED_LOW_WINDOWS = 3 };
static tetra_candidate_callback_t candidate_callback;
static uint64_t power_sum;
static uint32_t samples_in_window;
static uint32_t high_windows, low_windows, candidate_count, current_candidate;
static uint32_t active_windows;
static float noise_dbfs;
static float active_strength_dbfs;
static bool have_noise, active;

static void process_window(void)
{
    if (!samples_in_window) return;
    const float mean_power = (float)power_sum / (float)samples_in_window;
    const float dbfs = 10.0f * log10f(fmaxf(mean_power / (2.0f * 127.5f * 127.5f), 1.0e-9f));
    power_sum = 0;
    samples_in_window = 0;

    if (!have_noise) {
        noise_dbfs = dbfs;
        have_noise = true;
        return;
    }

    const bool elevated = dbfs >= noise_dbfs + 6.0f;
    if (elevated) {
        if (high_windows < REQUIRED_HIGH_WINDOWS) high_windows++;
        low_windows = 0;
        if (!active && high_windows >= REQUIRED_HIGH_WINDOWS) {
            active = true;
            candidate_count++;
            current_candidate = candidate_count;
            active_strength_dbfs = dbfs;
            active_windows = 0;
            if (candidate_callback) candidate_callback(current_candidate, dbfs, true);
        } else if (active && dbfs > active_strength_dbfs) {
            active_strength_dbfs = dbfs;
        }
        if (active && ++active_windows >= WINDOWS_PER_UPDATE) {
            active_windows = 0;
            if (candidate_callback) candidate_callback(current_candidate, dbfs, false);
        }
    } else {
        high_windows = 0;
        if (active) {
            if (low_windows < REQUIRED_LOW_WINDOWS) low_windows++;
            if (low_windows >= REQUIRED_LOW_WINDOWS) active = false;
        }
        // Track the local noise only while no candidate is active and the level
        // is near the current floor. This avoids learning an intermittent burst.
        if (!active && dbfs <= noise_dbfs + 3.0f) {
            noise_dbfs += (dbfs - noise_dbfs) * 0.05f;
        }
    }
}

void tetra_detector_set_callback(tetra_candidate_callback_t callback)
{
    candidate_callback = callback;
}

void tetra_detector_reset_stream(void)
{
    power_sum = 0;
    samples_in_window = 0;
    high_windows = 0;
    low_windows = 0;
    active_windows = 0;
    have_noise = false;
    active = false;
}

void tetra_detector_reset(void)
{
    tetra_detector_reset_stream();
    candidate_count = 0;
    current_candidate = 0;
    active_strength_dbfs = -120.0f;
}

uint32_t tetra_detector_candidate_count(void) { return candidate_count; }
bool tetra_detector_active(void) { return active; }

void tetra_detector_consume(const uint8_t *samples, size_t byte_count,
                            uint32_t center_hz, uint32_t sample_rate, uint32_t sequence)
{
    (void)center_hz;
    (void)sequence;
    if (!samples || sample_rate != 250000) return;
    for (size_t offset = 0; offset + 1 < byte_count; offset += 2) {
        const int i = (int)samples[offset] - 127;
        const int q = (int)samples[offset + 1] - 127;
        power_sum += (uint64_t)(i * i + q * q);
        samples_in_window++;
        if (samples_in_window >= WINDOW_SAMPLES) process_window();
    }
}
