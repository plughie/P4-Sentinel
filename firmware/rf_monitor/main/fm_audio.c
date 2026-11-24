#include "fm_audio.h"

#include <math.h>
#include <stdbool.h>

enum { INPUT_RATE = 250000, OUTPUT_RATE = 8000, AUDIO_BLOCK = 1600 };
static float previous_i, previous_q, lowpass, dc_block_input, dc_block_output;
static uint32_t phase_accumulator;
static bool have_previous;
static int8_t block[AUDIO_BLOCK];
static size_t block_count;
static fm_audio_callback_t callback;
static uint64_t input_samples, output_samples, emitted_blocks;

void fm_audio_set_callback(fm_audio_callback_t next) { callback = next; }
uint64_t fm_audio_input_samples(void) { return input_samples; }
uint64_t fm_audio_output_samples(void) { return output_samples; }
uint64_t fm_audio_emitted_blocks(void) { return emitted_blocks; }

void fm_audio_reset(void)
{
    previous_i = previous_q = lowpass = dc_block_input = dc_block_output = 0.0f;
    phase_accumulator = 0;
    have_previous = false;
    block_count = 0;
    input_samples = output_samples = emitted_blocks = 0;
}

void fm_audio_consume(const uint8_t *samples, size_t byte_count, uint32_t center_hz,
                      uint32_t sample_rate, uint32_t sequence)
{
    (void)center_hz;
    (void)sequence;
    if (!samples || sample_rate != INPUT_RATE) return;
    input_samples += byte_count / 2;
    const float lp_alpha = 1.0f - expf(-6.28318530718f * 3000.0f / INPUT_RATE);
    const float dc_alpha = 1.0f - expf(-6.28318530718f * 180.0f / OUTPUT_RATE);
    for (size_t offset = 0; offset + 1 < byte_count; offset += 2) {
        const float i = (float)((int)samples[offset] - 127);
        const float q = (float)((int)samples[offset + 1] - 127);
        if (have_previous) {
            const float cross = previous_i * q - previous_q * i;
            const float dot = previous_i * i + previous_q * q;
            float discriminator = atan2f(cross, dot);
            lowpass += lp_alpha * (discriminator - lowpass);
            phase_accumulator += OUTPUT_RATE;
            if (phase_accumulator >= INPUT_RATE) {
                phase_accumulator -= INPUT_RATE;
                const float dc_blocked = lowpass - dc_block_input + (1.0f - dc_alpha) * dc_block_output;
                dc_block_input = lowpass;
                dc_block_output = dc_blocked;
                /* 0.063 rad/sample is approximately ±2.5 kHz deviation at 250 kS/s. */
                float scaled = dc_blocked * (127.0f / 0.063f);
                if (scaled > 127.0f) scaled = 127.0f;
                if (scaled < -127.0f) scaled = -127.0f;
                block[block_count++] = (int8_t)lrintf(scaled);
                output_samples++;
                if (block_count == AUDIO_BLOCK) {
                    emitted_blocks++;
                    if (callback) callback(block, block_count);
                    block_count = 0;
                }
            }
        }
        previous_i = i;
        previous_q = q;
        have_previous = true;
    }
}
