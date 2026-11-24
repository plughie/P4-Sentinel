#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_rtl_sdr.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "rf_iq_pipeline.h"
#include "adsb_decoder.h"
#include "tetra_detector.h"
#include "p25_decoder.h"
#include "pocsag_decoder.h"
#include "fm_audio.h"
#include "tpms_decoder.h"
#include "frequency_finder.h"
#include "rf_storage.h"
#include "app_slots.h"

#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
#include "apps.h"
#endif

enum {
    FFT_SIZE = 512, AVERAGES = 16, SAMPLE_RATE = 960000, GAIN_TENTHS_DB = 297,
    IQ_SAMPLE_RATE = 250000, ADSB_SAMPLE_RATE = 2048000, ADSB_CENTER_HZ = 1090000000,
    IQ_CHUNK_BYTES = 8192, IQ_PREVIEW_POINTS = 128,
    RTL_TRANSFER_BYTES = 16384,
    MIN_CAPTURE_HZ = 87500000, MAX_CAPTURE_HZ = 468500000
};
static const float tau = 6.28318530718f;
static esp_rtl_sdr_handle_t radio;
static bool streaming;
static uint32_t center_hz;
static int64_t last_command_us;
static bool iq_capture;
static bool adsb_capture;
static bool tetra_capture;
static bool p25_capture;
static bool pager_capture;
static bool audio_capture;
static bool tpms_capture;
static bool find_capture;
static bool find_armed_announced;
static uint32_t iq_sequence;
static uint64_t iq_samples, iq_dropped_samples;
static int64_t iq_started_us, iq_last_metrics_us;
static size_t iq_chunk_filled;
static esp_rtl_sdr_metrics_t iq_previous_metrics;
static void emit_iq_metrics(bool force);
static void adsb_emit_frame(const adsb_frame_t *frame);
static void tetra_emit_candidate(uint32_t candidate_id, float strength_dbfs, bool new_candidate);
static void p25_emit_nid(uint16_t nac, uint8_t duid, uint32_t valid_count);
static void p25_emit_control_candidate(uint16_t nac, uint32_t repeated_count);
static void pager_emit_address(uint32_t capcode, uint8_t function);
static void pager_emit_message(uint32_t capcode, uint8_t function, const char *text);
static void audio_emit_block(const int8_t *samples, size_t count);
static void tpms_emit_packet(uint32_t id, uint8_t flags, uint16_t pressure_hpa, int16_t temperature_c);
bool rf_iq_capture_active(void);
typedef struct {
    float window[FFT_SIZE];
    float twiddle_real[FFT_SIZE / 2], twiddle_imag[FFT_SIZE / 2];
    uint16_t reversed[FFT_SIZE];
    float real[FFT_SIZE], imag[FFT_SIZE], power[FFT_SIZE];
    float find_power[FFT_SIZE];
    float window_sum;
    uint8_t iq[FFT_SIZE * 2], discard[16384], iq_chunk[IQ_CHUNK_BYTES];
    int16_t preview_i[IQ_PREVIEW_POINTS], preview_q[IQ_PREVIEW_POINTS];
    uint32_t preview_sequence;
    bool preview_ready;
    char frame[4096];
} capture_workspace_t;

static capture_workspace_t *workspace;
static SemaphoreHandle_t output_mutex;
static SemaphoreHandle_t serial_record_mutex;
static char serial_partial_line[4096];
static char serial_completed_line[4096];
static char serial_format_buffer[4096];
static size_t serial_partial_length;
static void capture_iq_preview(const uint8_t *samples, size_t byte_count, uint32_t sequence);
static void process_find_chunk(const uint8_t *samples, size_t byte_count);

static void route_serial_record_bytes(const char *bytes, size_t length)
{
    for (size_t index = 0; index < length; ++index) {
        const char byte = bytes[index];
        if (serial_partial_length < sizeof(serial_partial_line) - 1) {
            serial_partial_line[serial_partial_length++] = byte;
        } else {
            serial_partial_length = 0;
        }
        if (byte == '\n' && serial_partial_length) {
            const size_t complete_length = serial_partial_length;
            memcpy(serial_completed_line, serial_partial_line, complete_length);
            serial_partial_length = 0;
            rf_storage_record_event(serial_completed_line, complete_length);
        }
    }
}

static int rf_printf(const char *format, ...)
{
    va_list args, copy;
    va_start(args, format);
    va_copy(copy, args);
    if (serial_record_mutex) xSemaphoreTake(serial_record_mutex, portMAX_DELAY);
    const int result = vprintf(format, args);
    va_end(args);
    const int length = vsnprintf(serial_format_buffer, sizeof(serial_format_buffer), format, copy);
    va_end(copy);
    if (length > 0 && (size_t)length < sizeof(serial_format_buffer)) {
        route_serial_record_bytes(serial_format_buffer, (size_t)length);
    }
    if (serial_record_mutex) xSemaphoreGive(serial_record_mutex);
    return result;
}

static int rf_puts(const char *text)
{
    if (serial_record_mutex) xSemaphoreTake(serial_record_mutex, portMAX_DELAY);
    const int result = puts(text);
    if (result != EOF && text) {
        route_serial_record_bytes(text, strlen(text));
        route_serial_record_bytes("\n", 1);
    }
    if (serial_record_mutex) xSemaphoreGive(serial_record_mutex);
    return result;
}

#define printf rf_printf
#define puts rf_puts

static void emit_storage_status(void)
{
    const char *error = rf_storage_last_error();
    printf("@RF {\"type\":\"sd_status\",\"mounted\":%s,\"logging\":%s,"
           "\"capacity_bytes\":%" PRIu64 ",\"free_bytes\":%" PRIu64
           ",\"faa_master_present\":%s,\"path\":\"/sdcard/RF_SENTINEL\"",
           rf_storage_is_mounted() ? "true" : "false",
           rf_storage_is_logging() ? "true" : "false",
           rf_storage_capacity_bytes(), rf_storage_free_bytes(),
           rf_storage_faa_master_present() ? "true" : "false");
    if (error && error[0]) printf(",\"error\":\"%s\"", error);
    puts("}");
    fflush(stdout);
}

static void emit_faa_match(const char *address, const char *registration,
                           const char *year, const char *aircraft_type,
                           const char *last_action_date)
{
    printf("@RF {\"type\":\"faa_match\",\"icao\":\"%s\",\"registration\":\"%s\","
           "\"year\":\"%s\",\"aircraft_type\":\"%s\",\"last_action_date\":\"%s\","
           "\"source\":\"FAA Registry MASTER.txt\"}\n",
           address, registration, year, aircraft_type, last_action_date);
    fflush(stdout);
}

static bool cancellation_requested(void)
{
#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
    return apps_back_requested();
#else
    return false;
#endif
}

static void init_fft(void)
{
    for (unsigned index = 0; index < FFT_SIZE; ++index) {
        unsigned bits = index;
        for (unsigned width = FFT_SIZE; width > 1; width >>= 1) {
            workspace->reversed[index] = (workspace->reversed[index] << 1) | (bits & 1);
            bits >>= 1;
        }
        workspace->window[index] = 0.5f - 0.5f * cosf(tau * index / (FFT_SIZE - 1));
        workspace->window_sum += workspace->window[index];
    }
    for (unsigned index = 0; index < FFT_SIZE / 2; ++index) {
        workspace->twiddle_real[index] = cosf(tau * index / FFT_SIZE);
        workspace->twiddle_imag[index] = -sinf(tau * index / FFT_SIZE);
    }
}

static void accumulate_fft(void)
{
    for (unsigned i = 0; i < FFT_SIZE; ++i) {
        const float scale = workspace->window[i] / 128.0f;
        workspace->real[workspace->reversed[i]] = (workspace->iq[2 * i] - 127.5f) * scale;
        workspace->imag[workspace->reversed[i]] = (workspace->iq[2 * i + 1] - 127.5f) * scale;
    }
    for (unsigned span = 2; span <= FFT_SIZE; span *= 2) {
        const unsigned half = span / 2;
        for (unsigned base = 0; base < FFT_SIZE; base += span) {
            for (unsigned offset = 0; offset < half; ++offset) {
                const unsigned a = base + offset, b = a + half;
                const unsigned twiddle = offset * (FFT_SIZE / span);
                const float tr = workspace->real[b] * workspace->twiddle_real[twiddle] - workspace->imag[b] * workspace->twiddle_imag[twiddle];
                const float ti = workspace->real[b] * workspace->twiddle_imag[twiddle] + workspace->imag[b] * workspace->twiddle_real[twiddle];
                workspace->real[b] = workspace->real[a] - tr;
                workspace->imag[b] = workspace->imag[a] - ti;
                workspace->real[a] += tr;
                workspace->imag[a] += ti;
            }
        }
    }
    for (unsigned i = 0; i < FFT_SIZE; ++i) {
        workspace->power[i] += workspace->real[i] * workspace->real[i] + workspace->imag[i] * workspace->imag[i];
    }
}

static esp_err_t open_radio(void)
{
    if (!radio) {
        esp_rtl_sdr_config_t config;
        esp_rtl_sdr_config_default(&config);
        config.transfer_count = 6;
        config.transfer_bytes = 16384;
        config.delivery_mode = ESP_RTL_SDR_DELIVERY_READ;
        esp_err_t result = esp_rtl_sdr_install(&config, &radio);
        if (result != ESP_OK) return result;
    }
    esp_rtl_sdr_device_info_t device = {0};
    for (int attempt = 0; attempt < 20; ++attempt) {
        if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
        if (esp_rtl_sdr_get_device_info(radio, &device) == ESP_OK && device.present) return ESP_OK;
        vTaskDelay(pdMS_TO_TICKS(150));
    }
    return ESP_ERR_NOT_FOUND;
}

static esp_err_t stop_stream(void)
{
    if ((iq_capture || adsb_capture || tetra_capture || p25_capture || pager_capture || audio_capture || tpms_capture || find_capture) && workspace && iq_chunk_filled) {
        const size_t complete = iq_chunk_filled & ~(size_t)1;
        if (complete) {
            const uint32_t sequence = iq_sequence++;
            if (iq_capture) capture_iq_preview(workspace->iq_chunk, complete, sequence);
            if (find_capture) process_find_chunk(workspace->iq_chunk, complete);
            else rf_iq_pipeline_publish(workspace->iq_chunk, complete, center_hz,
                                         iq_capture || tetra_capture || p25_capture || pager_capture || audio_capture || tpms_capture ? IQ_SAMPLE_RATE : ADSB_SAMPLE_RATE, sequence);
            iq_samples += complete / 2;
        }
        iq_chunk_filled = 0;
    }
    if (pager_capture) pocsag_decoder_finish();
    if (iq_capture || adsb_capture || tetra_capture || p25_capture || pager_capture || tpms_capture || find_capture) emit_iq_metrics(true);
    rf_iq_pipeline_set_consumer(NULL);
    iq_capture = false;
    adsb_capture = false;
    tetra_capture = false;
    p25_capture = false;
    pager_capture = false;
    audio_capture = false;
    tpms_capture = false;
    find_capture = false;
    if (!streaming) return ESP_OK;
    esp_err_t result = esp_rtl_sdr_stop(radio, 1500);
    if (result == ESP_OK) streaming = false;
    return result;
}

static uint32_t delta_u32(uint32_t before, uint32_t after)
{
    return after >= before ? after - before : after;
}

static uint64_t delta_u64(uint64_t before, uint64_t after)
{
    return after >= before ? after - before : after;
}

static void capture_iq_preview(const uint8_t *samples, size_t byte_count, uint32_t sequence)
{
    if (!samples || byte_count < 2) return;
    const size_t complex_samples = byte_count / 2;
    for (size_t point = 0; point < IQ_PREVIEW_POINTS; ++point) {
        const size_t index = point * complex_samples / IQ_PREVIEW_POINTS;
        workspace->preview_i[point] = (int16_t)samples[2 * index] - 128;
        workspace->preview_q[point] = (int16_t)samples[2 * index + 1] - 128;
    }
    workspace->preview_sequence = sequence;
    workspace->preview_ready = true;
}

static void emit_iq_preview(void)
{
    if (!workspace->preview_ready) return;
    size_t used = (size_t)snprintf(workspace->frame, sizeof(workspace->frame),
        "@RF {\"type\":\"iq_waveform\",\"center\":%" PRIu32
        ",\"rate\":%u,\"sequence\":%" PRIu32 ",\"i\":[",
        center_hz, IQ_SAMPLE_RATE, workspace->preview_sequence);
    for (size_t point = 0; point < IQ_PREVIEW_POINTS; ++point) {
        const int written = snprintf(workspace->frame + used, sizeof(workspace->frame) - used,
                                     "%s%d", point ? "," : "", workspace->preview_i[point]);
        if (written < 0 || (size_t)written >= sizeof(workspace->frame) - used) return;
        used += (size_t)written;
    }
    const int q_start = snprintf(workspace->frame + used, sizeof(workspace->frame) - used, "],\"q\":[");
    if (q_start < 0 || (size_t)q_start >= sizeof(workspace->frame) - used) return;
    used += (size_t)q_start;
    for (size_t point = 0; point < IQ_PREVIEW_POINTS; ++point) {
        const int written = snprintf(workspace->frame + used, sizeof(workspace->frame) - used,
                                     "%s%d", point ? "," : "", workspace->preview_q[point]);
        if (written < 0 || (size_t)written >= sizeof(workspace->frame) - used) return;
        used += (size_t)written;
    }
    const int end = snprintf(workspace->frame + used, sizeof(workspace->frame) - used, "]}\n");
    if (end < 0 || (size_t)end >= sizeof(workspace->frame) - used) return;
    fputs(workspace->frame, stdout);
    fflush(stdout);
    workspace->preview_ready = false;
}

static void emit_iq_metrics(bool force)
{
    const int64_t now = esp_timer_get_time();
    if (!force && now - iq_last_metrics_us < 1000000) return;

    esp_rtl_sdr_metrics_t current = {0};
    if (esp_rtl_sdr_get_metrics(radio, &current) == ESP_OK) {
        const uint64_t lost_bytes =
            (uint64_t)delta_u32(iq_previous_metrics.slot_starve_blocks,
                                current.slot_starve_blocks) * RTL_TRANSFER_BYTES
            + delta_u64(iq_previous_metrics.ring_overrun_bytes,
                        current.ring_overrun_bytes)
            + delta_u64(iq_previous_metrics.pull_lock_miss_bytes,
                        current.pull_lock_miss_bytes);
        iq_dropped_samples += lost_bytes / 2;
        if (lost_bytes && adsb_capture) adsb_decoder_reset_stream();
        if (lost_bytes && tetra_capture) tetra_detector_reset_stream();
        if (lost_bytes && p25_capture) p25_decoder_reset_stream();
        if (lost_bytes && pager_capture) pocsag_decoder_reset_stream();
        if (lost_bytes && tpms_capture) tpms_decoder_reset_stream();
        if (lost_bytes && find_capture) {
            frequency_finder_reset();
            find_armed_announced = false;
            puts("@RF {\"type\":\"find_learning\"}");
            fflush(stdout);
        }
        iq_previous_metrics = current;
    }
    if (output_mutex) xSemaphoreTake(output_mutex, portMAX_DELAY);
    if (iq_capture) {
        emit_iq_preview();
        printf("@RF {\"type\":\"iq_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64 "}\n",
               IQ_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples);
    } else if (adsb_capture) {
        printf("@RF {\"type\":\"adsb_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64
               ",\"valid_frames\":%" PRIu64 "}\n",
               ADSB_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples, adsb_decoder_valid_frames());
    } else if (tetra_capture) {
        printf("@RF {\"type\":\"tetra_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64
               ",\"candidate_count\":%" PRIu32 ",\"active\":%s}\n",
               (unsigned)IQ_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples, tetra_detector_candidate_count(),
               tetra_detector_active() ? "true" : "false");
    } else if (p25_capture) {
        printf("@RF {\"type\":\"p25_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64
               ",\"valid_nids\":%" PRIu32 ",\"control_nids\":%" PRIu32
               ",\"control_nac\":%u}\n",
               (unsigned)IQ_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples, p25_decoder_valid_nids(),
               p25_decoder_control_nids(), (unsigned)p25_decoder_control_nac());
    } else if (pager_capture) {
        printf("@RF {\"type\":\"pager_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64
               ",\"valid_words\":%" PRIu32 "}\n",
               (unsigned)IQ_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples, pocsag_decoder_valid_words());
    } else if (tpms_capture) {
        printf("@RF {\"type\":\"tpms_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64
               ",\"valid_packets\":%" PRIu32 "}\n",
               (unsigned)IQ_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples, tpms_decoder_valid_packets());
    } else if (find_capture) {
        printf("@RF {\"type\":\"find_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64 "}\n",
               (unsigned)SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples);
    } else if (audio_capture) {
        printf("@RF {\"type\":\"audio_metrics\",\"rate\":%u,\"elapsed_ms\":%" PRIu64
               ",\"samples\":%" PRIu64 ",\"dropped_samples\":%" PRIu64
               ",\"demod_samples\":%" PRIu64 ",\"firmware_blocks\":%" PRIu64 "}\n",
               (unsigned)IQ_SAMPLE_RATE, (uint64_t)((now - iq_started_us) / 1000),
               iq_samples, iq_dropped_samples, fm_audio_output_samples(), fm_audio_emitted_blocks());
    }
    fflush(stdout);
    if (output_mutex) xSemaphoreGive(output_mutex);
    iq_last_metrics_us = now;
}

static esp_err_t start_iq_capture(uint32_t hz)
{
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, IQ_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) {
        (void)stop_stream();
        return result;
    }

    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) {
        (void)stop_stream();
        return result;
    }
    iq_capture = true;
    adsb_capture = false;
    iq_sequence = 0;
    iq_samples = 0;
    iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"iq_started\",\"center\":%" PRIu32
           ",\"rate\":%u}\n", hz, IQ_SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static void process_find_chunk(const uint8_t *samples, size_t byte_count)
{
    if (!samples || !workspace || !find_capture) return;
    const size_t complex_count = byte_count / 2;
    for (size_t offset = 0; offset + FFT_SIZE <= complex_count; offset += 1024) {
        for (size_t index = 0; index < FFT_SIZE; ++index) {
            workspace->iq[2 * index] = samples[2 * (offset + index)];
            workspace->iq[2 * index + 1] = samples[2 * (offset + index) + 1];
        }
        memset(workspace->power, 0, sizeof(workspace->power));
        accumulate_fft();
        for (size_t bin = 0; bin < FFT_SIZE; ++bin)
            workspace->find_power[bin] = workspace->power[(bin + FFT_SIZE / 2) % FFT_SIZE];
        frequency_finder_candidate_t candidate = {0};
        const frequency_finder_result_t result = frequency_finder_observe(
            workspace->find_power, center_hz, SAMPLE_RATE, &candidate);
        if (result == FREQUENCY_FINDER_ARMED && !find_armed_announced) {
            find_armed_announced = true;
            printf("@RF {\"type\":\"find_armed\",\"center\":%" PRIu32 "}\n", center_hz);
            fflush(stdout);
        } else if (result == FREQUENCY_FINDER_CANDIDATE) {
            printf("@RF {\"type\":\"find_result\",\"center\":%" PRIu32
                   ",\"frequency\":%" PRIu32 ",\"rise_db\":%.1f,\"resolution_hz\":%u}\n",
                   center_hz, candidate.frequency_hz, (double)candidate.rise_db,
                   (unsigned)(SAMPLE_RATE / FFT_SIZE));
            fflush(stdout);
        }
    }
}

static esp_err_t start_find_capture(uint32_t hz)
{
    if (hz < MIN_CAPTURE_HZ || hz > MAX_CAPTURE_HZ) return ESP_ERR_INVALID_ARG;
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    frequency_finder_reset();
    find_capture = true;
    iq_capture = adsb_capture = tetra_capture = p25_capture = pager_capture = audio_capture = tpms_capture = false;
    find_armed_announced = false;
    iq_sequence = 0;
    iq_samples = iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"find_started\",\"center\":%" PRIu32 ",\"rate\":%u}\n",
           hz, (unsigned)SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static esp_err_t start_adsb_capture(void)
{
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, ADSB_CENTER_HZ, ADSB_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = ADSB_CENTER_HZ;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) {
        (void)stop_stream();
        return result;
    }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) {
        (void)stop_stream();
        return result;
    }
    adsb_decoder_reset();
    adsb_decoder_set_callback(adsb_emit_frame);
    rf_iq_pipeline_set_consumer(adsb_decoder_consume);
    adsb_capture = true;
    iq_capture = false;
    iq_sequence = 0;
    iq_samples = 0;
    iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"adsb_started\",\"center\":%" PRIu32
           ",\"rate\":%u}\n", (uint32_t)ADSB_CENTER_HZ, (unsigned)ADSB_SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static esp_err_t start_tetra_capture(uint32_t hz)
{
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, IQ_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    tetra_detector_reset();
    tetra_detector_set_callback(tetra_emit_candidate);
    rf_iq_pipeline_set_consumer(tetra_detector_consume);
    tetra_capture = true;
    iq_capture = false;
    adsb_capture = false;
    iq_sequence = 0;
    iq_samples = 0;
    iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"tetra_started\",\"center\":%" PRIu32
           ",\"rate\":%u}\n", hz, (unsigned)IQ_SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static esp_err_t start_p25_capture(uint32_t hz)
{
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, IQ_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    p25_decoder_reset();
    p25_decoder_set_callback(p25_emit_nid);
    p25_decoder_set_control_callback(p25_emit_control_candidate);
    rf_iq_pipeline_set_consumer(p25_decoder_consume);
    p25_capture = true;
    iq_capture = adsb_capture = tetra_capture = false;
    iq_sequence = 0;
    iq_samples = iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"p25_started\",\"center\":%" PRIu32 ",\"rate\":%u}\n",
           hz, (unsigned)IQ_SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static esp_err_t start_pager_capture(uint32_t hz, uint16_t baud)
{
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, IQ_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    pocsag_decoder_reset();
    pocsag_decoder_set_baud(baud);
    pocsag_decoder_set_callbacks(pager_emit_address, pager_emit_message);
    rf_iq_pipeline_set_consumer(pocsag_decoder_consume);
    pager_capture = true;
    iq_capture = adsb_capture = tetra_capture = p25_capture = false;
    iq_sequence = 0;
    iq_samples = iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"pager_started\",\"center\":%" PRIu32
           ",\"rate\":%u,\"baud\":%u}\n", hz, (unsigned)IQ_SAMPLE_RATE, (unsigned)baud);
    fflush(stdout);
    return ESP_OK;
}

static esp_err_t start_audio_capture(uint32_t hz)
{
    if (hz < 462000000 || hz > 468000000) return ESP_ERR_INVALID_ARG;
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, IQ_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    fm_audio_reset();
    fm_audio_set_callback(audio_emit_block);
    rf_iq_pipeline_set_consumer(fm_audio_consume);
    audio_capture = true;
    iq_capture = adsb_capture = tetra_capture = p25_capture = pager_capture = false;
    iq_sequence = 0;
    iq_samples = iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"audio_started\",\"center\":%" PRIu32 ",\"rate\":%u,\"audio_rate\":8000}\n",
           hz, (unsigned)IQ_SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static void audio_emit_block(const int8_t *samples, size_t count)
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    static const int16_t steps[89] = {
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767
    };
    static const int8_t index_adjust[16] = {-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8};
    if (!samples || !count) return;
    /* One predictor header plus packed 4-bit IMA ADPCM deltas. */
    uint8_t compressed[803] = {0};
    const int16_t first = (int16_t)((int16_t)samples[0] * 256);
    compressed[0] = (uint8_t)first;
    compressed[1] = (uint8_t)((uint16_t)first >> 8);
    compressed[2] = 0;
    int32_t predictor = first;
    int step_index = 0;
    for (size_t index = 1; index < count; ++index) {
        const int32_t target = (int16_t)((int16_t)samples[index] * 256);
        int32_t difference = target - predictor;
        uint8_t code = 0;
        if (difference < 0) { code = 8; difference = -difference; }
        const int32_t step = steps[step_index];
        int32_t delta = step >> 3;
        if (difference >= step) { code |= 4; difference -= step; delta += step; }
        if (difference >= (step >> 1)) { code |= 2; difference -= step >> 1; delta += step >> 1; }
        if (difference >= (step >> 2)) { code |= 1; delta += step >> 2; }
        predictor += (code & 8) ? -delta : delta;
        if (predictor > 32767) predictor = 32767;
        if (predictor < -32768) predictor = -32768;
        step_index += index_adjust[code];
        if (step_index > 88) step_index = 88;
        if (step_index < 0) step_index = 0;
        const size_t nibble = index - 1;
        if ((nibble & 1u) == 0) compressed[3 + nibble / 2] = code;
        else compressed[3 + nibble / 2] |= (uint8_t)(code << 4);
    }
    const size_t compressed_count = 3 + count / 2;
    if (output_mutex) xSemaphoreTake(output_mutex, portMAX_DELAY);
    printf("@RF {\"type\":\"audio_pcm\",\"center\":%" PRIu32
           ",\"rate\":8000,\"codec\":\"ima_adpcm4\",\"samples\":%zu,\"pcm\":\"",
           center_hz, count);
    for (size_t index = 0; index < compressed_count; index += 3) {
        const uint32_t a = compressed[index];
        const uint32_t b = index + 1 < compressed_count ? compressed[index + 1] : 0;
        const uint32_t c = index + 2 < compressed_count ? compressed[index + 2] : 0;
        const uint32_t bits = (a << 16) | (b << 8) | c;
        putchar(alphabet[(bits >> 18) & 63]);
        putchar(alphabet[(bits >> 12) & 63]);
        putchar(index + 1 < compressed_count ? alphabet[(bits >> 6) & 63] : '=');
        putchar(index + 2 < compressed_count ? alphabet[bits & 63] : '=');
    }
    puts("\"}");
    fflush(stdout);
    if (output_mutex) xSemaphoreGive(output_mutex);
}

static esp_err_t start_tpms_capture(uint32_t hz)
{
    const bool supported = (hz >= 314000000 && hz <= 316000000)
        || (hz >= 433800000 && hz <= 434000000);
    if (!supported) return ESP_ERR_INVALID_ARG;
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, IQ_SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    if (result == ESP_OK && cancellation_requested()) result = ESP_ERR_INVALID_STATE;
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    memset(&iq_previous_metrics, 0, sizeof(iq_previous_metrics));
    result = esp_rtl_sdr_get_metrics(radio, &iq_previous_metrics);
    if (result != ESP_OK) { (void)stop_stream(); return result; }
    tpms_decoder_reset();
    tpms_decoder_set_callback(tpms_emit_packet);
    rf_iq_pipeline_set_consumer(tpms_decoder_consume);
    tpms_capture = true;
    iq_capture = adsb_capture = tetra_capture = p25_capture = pager_capture = audio_capture = false;
    iq_sequence = 0;
    iq_samples = iq_dropped_samples = 0;
    iq_chunk_filled = 0;
    iq_started_us = esp_timer_get_time();
    iq_last_metrics_us = iq_started_us;
    last_command_us = iq_started_us;
    printf("@RF {\"type\":\"tpms_started\",\"center\":%" PRIu32 ",\"rate\":%u}\n",
           hz, (unsigned)IQ_SAMPLE_RATE);
    fflush(stdout);
    return ESP_OK;
}

static void tpms_emit_packet(uint32_t id, uint8_t flags, uint16_t pressure_hpa, int16_t temperature_c)
{
    printf("@RF {\"type\":\"tpms_packet\",\"center\":%" PRIu32
           ",\"id\":\"%07" PRIX32 "\",\"flags\":%u,\"pressure_hpa\":%u,\"temperature_c\":%d}\n",
           center_hz, id, (unsigned)flags, (unsigned)pressure_hpa, (int)temperature_c);
    fflush(stdout);
}

static void adsb_emit_frame(const adsb_frame_t *frame)
{
    if (!frame) return;
    printf("@RF {\"type\":\"adsb_frame\",\"icao\":\"%06" PRIX32
           "\",\"df\":%u,\"type_code\":%u",
           frame->address, frame->downlink_format, frame->type_code);
    if (frame->has_callsign) printf(",\"callsign\":\"%s\"", frame->callsign);
    if (frame->has_altitude) {
        printf(",\"altitude_ft\":%" PRId32 ",\"altitude_kind\":\"%s\"",
               frame->altitude_ft, frame->geometric_altitude ? "geometric" : "barometric");
    }
    puts("}");
    fflush(stdout);
}

static void tetra_emit_candidate(uint32_t candidate_id, float strength_dbfs, bool new_candidate)
{
    printf("@RF {\"type\":\"tetra_%s\",\"candidate_id\":%" PRIu32
           ",\"center\":%" PRIu32 ",\"strength_dbfs\":%.1f}\n",
           new_candidate ? "candidate" : "strength", candidate_id, center_hz,
           (double)strength_dbfs);
    fflush(stdout);
}

static void p25_emit_nid(uint16_t nac, uint8_t duid, uint32_t valid_count)
{
    printf("@RF {\"type\":\"p25_nid\",\"center\":%" PRIu32
           ",\"nac\":%u,\"duid\":%u,\"valid_nids\":%" PRIu32 "}\n",
           center_hz, (unsigned)nac, (unsigned)duid, valid_count);
    fflush(stdout);
}

static void p25_emit_control_candidate(uint16_t nac, uint32_t repeated_count)
{
    printf("@RF {\"type\":\"p25_control_candidate\",\"center\":%" PRIu32
           ",\"nac\":%u,\"repeated_nids\":%" PRIu32 "}\n",
           center_hz, (unsigned)nac, repeated_count);
    fflush(stdout);
}

static void pager_emit_address(uint32_t capcode, uint8_t function)
{
    printf("@RF {\"type\":\"pager_address\",\"capcode\":%" PRIu32
           ",\"function\":%u,\"center\":%" PRIu32 "}\n",
           capcode, (unsigned)function, center_hz);
    fflush(stdout);
}

static void pager_emit_message(uint32_t capcode, uint8_t function, const char *text)
{
    printf("@RF {\"type\":\"pager_message\",\"capcode\":%" PRIu32 ",\"function\":%u,\"text\":\"",
           capcode, (unsigned)function);
    for (const unsigned char *cursor = (const unsigned char *)text; cursor && *cursor; ++cursor) {
        if (*cursor == '"' || *cursor == '\\') putchar('\\');
        if (*cursor >= 0x20 && *cursor <= 0x7e) putchar(*cursor);
        else putchar(' ');
    }
    puts("\"}");
    fflush(stdout);
}

static void read_iq_chunk(void)
{
    if ((!iq_capture && !adsb_capture && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture && !find_capture) || !workspace) return;
    if (cancellation_requested()) return;

    size_t received = 0;
    esp_err_t result = esp_rtl_sdr_read(radio, workspace->iq_chunk + iq_chunk_filled,
                                        IQ_CHUNK_BYTES - iq_chunk_filled, 10, &received);
    if (received) iq_chunk_filled += received;
    if (result != ESP_OK && result != ESP_RTL_SDR_ERR_TIMEOUT && result != ESP_ERR_TIMEOUT) {
        printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
        fflush(stdout);
        (void)stop_stream();
        return;
    }
    if (iq_chunk_filled >= IQ_CHUNK_BYTES) {
        const uint32_t sequence = iq_sequence++;
        if (iq_capture) capture_iq_preview(workspace->iq_chunk, IQ_CHUNK_BYTES, sequence);
        if (find_capture) process_find_chunk(workspace->iq_chunk, IQ_CHUNK_BYTES);
        else rf_iq_pipeline_publish(workspace->iq_chunk, IQ_CHUNK_BYTES, center_hz,
                                    iq_capture || tetra_capture || p25_capture || pager_capture || audio_capture || tpms_capture ? IQ_SAMPLE_RATE : ADSB_SAMPLE_RATE, sequence);
        iq_samples += IQ_CHUNK_BYTES / 2;
        iq_chunk_filled = 0;
    }
    emit_iq_metrics(false);
    last_command_us = esp_timer_get_time();
}

static esp_err_t tune(uint32_t hz)
{
    if (streaming) {
        if (hz == center_hz) return ESP_OK;
        esp_err_t result = esp_rtl_sdr_retune_hz(radio, hz);
        if (result == ESP_OK) center_hz = hz;
        return result;
    }
    esp_err_t result = open_radio();
    if (result != ESP_OK) return result;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_start_hz(radio, hz, SAMPLE_RATE);
    if (result != ESP_OK) return result;
    streaming = true;
    center_hz = hz;
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    result = esp_rtl_sdr_set_tuner_gain(radio, GAIN_TENTHS_DB);
    if (result == ESP_OK) result = esp_rtl_sdr_set_rtl_agc(radio, false);
    return result;
}

static esp_err_t measure(uint32_t hz)
{
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    const bool starting = !streaming;
    esp_err_t result = tune(hz);
    if (result != ESP_OK) return result;

    // The startup gain change can drain and resubmit USB transfers. Wait
    // for an initial block, then drain during the settling interval.
    size_t ignored;
    result = esp_rtl_sdr_read(radio, workspace->discard, sizeof(workspace->discard), 500, &ignored);
    if (result != ESP_OK) return result;
    const int64_t settle_until = esp_timer_get_time() + (starting ? 180000 : 80000);
    do {
        if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
        result = esp_rtl_sdr_read(radio, workspace->discard, sizeof(workspace->discard), 200, &ignored);
        if (result != ESP_OK) return result;
    } while (esp_timer_get_time() < settle_until);

    esp_rtl_sdr_metrics_t before = {0}, after = {0};
    result = esp_rtl_sdr_get_metrics(radio, &before);
    if (result != ESP_OK) return result;
    memset(workspace->power, 0, sizeof(workspace->power));
    for (unsigned i = 0; i < AVERAGES; ++i) {
        if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
        size_t offset = 0;
        while (offset < sizeof(workspace->iq)) {
            size_t got = 0;
            result = esp_rtl_sdr_read(radio, workspace->iq + offset, sizeof(workspace->iq) - offset, 200, &got);
            if (result != ESP_OK) return result;
            if (!got) return ESP_ERR_TIMEOUT;
            offset += got;
        }
        accumulate_fft();
    }
    result = esp_rtl_sdr_get_metrics(radio, &after);
    if (result != ESP_OK) return result;
    const uint32_t dropped = after.slot_starve_blocks - before.slot_starve_blocks
        + after.ring_overrun_blocks - before.ring_overrun_blocks
        + after.pull_lock_miss_blocks - before.pull_lock_miss_blocks;
    size_t used = snprintf(workspace->frame, sizeof(workspace->frame),
           "@RF {\"type\":\"frame\",\"center\":%" PRIu32 ",\"rate\":%" PRIu32
           ",\"drops\":%" PRIu32 ",\"bins\":[",
           after.frequency_hz, after.sample_rate_sps, dropped);
    const float normalization = workspace->window_sum * workspace->window_sum * AVERAGES;
    for (unsigned i = 0; i < FFT_SIZE; ++i) {
        const float level = workspace->power[(i + FFT_SIZE / 2) % FFT_SIZE] / normalization;
        const int written = snprintf(workspace->frame + used, sizeof(workspace->frame) - used, "%s%d",
                                     i ? "," : "", (int)lroundf(100.0f * log10f(fmaxf(level, 1e-12f))));
        if (written < 0 || (size_t)written >= sizeof(workspace->frame) - used - 2) return ESP_ERR_INVALID_SIZE;
        used += written;
    }
    memcpy(workspace->frame + used, "]}", 3);
    if (cancellation_requested()) return ESP_ERR_INVALID_STATE;
    puts(workspace->frame);
    return ESP_OK;
}

static void report_stop(void)
{
    const esp_err_t result = stop_stream();
    if (result == ESP_OK) {
        puts("@RF {\"type\":\"stopped\"}");
    } else {
        printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
    }
    fflush(stdout);
}

void rf_command(const char *line)
{
    if (strcmp(line, "status") == 0) {
        puts("@RF {\"type\":\"ready\"}");
        emit_storage_status();
    } else if (strcmp(line, "sd status") == 0) {
        emit_storage_status();
    } else if (strcmp(line, "sd logging on") == 0) {
        rf_storage_set_logging(true);
        emit_storage_status();
    } else if (strcmp(line, "sd logging off") == 0) {
        rf_storage_set_logging(false);
        emit_storage_status();
    } else if (strcmp(line, "sd export adsb") == 0) {
        uint32_t rows = 0;
        char path[96] = "";
        const esp_err_t result = rf_storage_export_adsb_csv(&rows, path, sizeof(path));
        if (result == ESP_OK) {
            printf("@RF {\"type\":\"sd_export\",\"ok\":true,\"rows\":%" PRIu32 ",\"path\":\"%s\"}\n",
                   rows, path);
        } else {
            printf("@RF {\"type\":\"sd_export\",\"ok\":false,\"rows\":0,\"error\":\"%s\"}\n",
                   rf_storage_last_error());
        }
    } else if (strncmp(line, "faa match ", 10) == 0) {
        if (streaming || rf_iq_capture_active()) {
            puts("@RF {\"type\":\"faa_match_complete\",\"ok\":false,\"matches\":0,"
                 "\"error\":\"Stop RF capture before searching the FAA catalog\"}");
            return;
        }
        uint32_t matches = 0;
        const esp_err_t result = rf_storage_match_faa_master(
            line + 10, emit_faa_match, &matches);
        if (result == ESP_OK) {
            printf("@RF {\"type\":\"faa_match_complete\",\"ok\":true,\"matches\":%" PRIu32 "}\n",
                   matches);
        } else {
            printf("@RF {\"type\":\"faa_match_complete\",\"ok\":false,\"matches\":0,\"error\":\"%s\"}\n",
                   rf_storage_last_error());
        }
    } else if (strcmp(line, "stop") == 0) {
        report_stop();
    } else if (strncmp(line, "iq ", 3) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 3, &end, 10);
        if (*end == '\0' && hz >= MIN_CAPTURE_HZ && hz <= MAX_CAPTURE_HZ
            && !streaming && !iq_capture && !adsb_capture && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_iq_capture((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "tetra ", 6) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 6, &end, 10);
        if (*end == '\0' && hz >= 380000000 && hz <= 470000000
            && !streaming && !iq_capture && !adsb_capture && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_tetra_capture((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "p25 ", 4) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 4, &end, 10);
        const bool supported = (hz >= 136000000 && hz <= 174000000)
            || (hz >= 380000000 && hz <= 520000000)
            || (hz >= 700000000 && hz <= 960000000);
        if (*end == '\0' && supported && !streaming && !iq_capture && !adsb_capture
            && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_p25_capture((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "pager ", 6) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 6, &end, 10);
        const unsigned long baud = (*end == ' ') ? strtoul(end + 1, &end, 10) : 0;
        const bool supported = (hz >= 138000000 && hz <= 174000000)
            || (hz >= 430000000 && hz <= 470000000)
            || (hz >= 929000000 && hz <= 932000000);
        if (*end == '\0' && supported && (baud == 512 || baud == 1200 || baud == 2400)
            && !streaming && !iq_capture && !adsb_capture && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_pager_capture((uint32_t)hz, (uint16_t)baud);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strcmp(line, "adsb") == 0 || strcmp(line, "adsb 1090000000") == 0) {
        if (!streaming && !iq_capture && !adsb_capture && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_adsb_capture();
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "audio ", 6) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 6, &end, 10);
        if (*end == '\0' && hz >= 462000000 && hz <= 468000000
            && !streaming && !iq_capture && !adsb_capture && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_audio_capture((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "tpms ", 5) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 5, &end, 10);
        const bool supported = (hz >= 314000000 && hz <= 316000000)
            || (hz >= 433800000 && hz <= 434000000);
        if (*end == '\0' && supported && !streaming && !iq_capture && !adsb_capture
            && !tetra_capture && !p25_capture && !pager_capture && !audio_capture && !tpms_capture) {
            esp_err_t result = start_tpms_capture((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "find ", 5) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 5, &end, 10);
        if (*end == '\0' && hz >= MIN_CAPTURE_HZ && hz <= MAX_CAPTURE_HZ
            && !streaming && !iq_capture && !adsb_capture && !tetra_capture
            && !p25_capture && !pager_capture && !audio_capture && !tpms_capture && !find_capture) {
            esp_err_t result = start_find_capture((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d}\n", result);
                (void)stop_stream();
            }
        }
    } else if (strncmp(line, "capture ", 8) == 0) {
        char *end;
        const unsigned long hz = strtoul(line + 8, &end, 10);
        if (*end == '\0' && hz >= MIN_CAPTURE_HZ && hz <= MAX_CAPTURE_HZ && !streaming) {
            esp_err_t result = measure((uint32_t)hz);
            if (result != ESP_OK && !cancellation_requested()) {
                printf("@RF {\"type\":\"error\",\"code\":%d,\"center\":%lu}\n", result, hz);
                (void)stop_stream();
            }
            last_command_us = esp_timer_get_time();
        }
    }
    fflush(stdout);
}

esp_err_t rf_enter(void)
{
    if (!output_mutex) {
        output_mutex = xSemaphoreCreateMutex();
        if (!output_mutex) return ESP_ERR_NO_MEM;
    }
    if (!serial_record_mutex) {
        serial_record_mutex = xSemaphoreCreateMutex();
        if (!serial_record_mutex) return ESP_ERR_NO_MEM;
    }
    if (workspace) return ESP_OK;
    workspace = calloc(1, sizeof(*workspace));
    if (!workspace) return ESP_ERR_NO_MEM;
    init_fft();
    const esp_err_t storage_result = rf_storage_init();
    if (storage_result != ESP_OK) {
        printf("@RF {\"type\":\"sd_error\",\"code\":%d}\n", storage_result);
    }
    emit_storage_status();
    return ESP_OK;
}

#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
esp_err_t rf_leave(void)
{
    const esp_err_t result = stop_stream();
    if (result != ESP_OK) return result;
    rf_storage_end_session();
    free(workspace);
    workspace = NULL;
    return ESP_OK;
}
#endif

void rf_idle(void)
{
    if (iq_capture || adsb_capture || tetra_capture || p25_capture || pager_capture || audio_capture || tpms_capture || find_capture) {
        read_iq_chunk();
        return;
    }
    if (streaming && esp_timer_get_time() - last_command_us >= 4000000) report_stop();
}

bool rf_iq_capture_active(void)
{
    return iq_capture || adsb_capture || tetra_capture || p25_capture || pager_capture || audio_capture || tpms_capture || find_capture;
}

#if !defined(APP_CHOOSER) && !defined(APP_SLOT_IMAGE)
void app_main(void)
{
    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 4096, .rx_buffer_size = 256};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    usb_serial_jtag_vfs_use_driver();
    ESP_ERROR_CHECK(app_slots_init());
    ESP_ERROR_CHECK(rf_enter());
    app_slots_announce("rf");

    char line[512];
    size_t length = 0;
    bool overflow = false;
    for (;;) {
        uint8_t byte;
        const TickType_t wait = rf_iq_capture_active() ? pdMS_TO_TICKS(1) : pdMS_TO_TICKS(100);
        if (usb_serial_jtag_read_bytes(&byte, 1, wait) != 1) {
            // Also release the interface when the Mac process goes away abruptly.
            rf_idle();
            continue;
        }
        if (byte == '\r') continue;
        if (byte == '\n') {
            line[length] = '\0';
            if (!overflow && !app_slots_parse_command(line, "rf")) rf_command(line);
            length = 0;
            overflow = false;
        } else if (length < sizeof(line) - 1) {
            line[length++] = (char)byte;
        } else {
            overflow = true;
        }
    }
}
#endif
