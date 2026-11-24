#pragma once

#include <stddef.h>
#include <stdint.h>

/*
 * Optional receive-only IQ consumer hook for on-device protocol detectors.
 * Samples are interleaved unsigned 8-bit I/Q (CU8) and remain valid only for
 * the duration of the callback. Consumers must return quickly so the RTL-SDR
 * transfer ring can keep up; heavy decoding should queue or copy the block.
 */
typedef void (*rf_iq_consumer_t)(const uint8_t *samples, size_t byte_count,
                                 uint32_t center_hz, uint32_t sample_rate_sps,
                                 uint32_t sequence);

void rf_iq_pipeline_set_consumer(rf_iq_consumer_t consumer);
void rf_iq_pipeline_publish(const uint8_t *samples, size_t byte_count,
                            uint32_t center_hz, uint32_t sample_rate_sps,
                            uint32_t sequence);
