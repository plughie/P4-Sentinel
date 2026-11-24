#include "rf_iq_pipeline.h"

static rf_iq_consumer_t consumer;

void rf_iq_pipeline_set_consumer(rf_iq_consumer_t next)
{
    consumer = next;
}

void rf_iq_pipeline_publish(const uint8_t *samples, size_t byte_count,
                            uint32_t center_hz, uint32_t sample_rate_sps,
                            uint32_t sequence)
{
    if (consumer && samples && byte_count >= 2 && (byte_count & 1u) == 0) {
        consumer(samples, byte_count, center_hz, sample_rate_sps, sequence);
    }
}
