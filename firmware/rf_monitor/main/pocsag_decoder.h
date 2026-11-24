#pragma once

#include <stddef.h>
#include <stdint.h>

typedef void (*pocsag_address_callback_t)(uint32_t capcode, uint8_t function);
typedef void (*pocsag_message_callback_t)(uint32_t capcode, uint8_t function, const char *text);

void pocsag_decoder_reset(void);
void pocsag_decoder_set_callbacks(pocsag_address_callback_t address_callback,
                                  pocsag_message_callback_t message_callback);
void pocsag_decoder_set_baud(uint16_t baud);
void pocsag_decoder_reset_stream(void);
void pocsag_decoder_finish(void);
uint32_t pocsag_decoder_valid_words(void);
void pocsag_decoder_consume_bits(const uint8_t *bits, size_t bit_count);
void pocsag_decoder_consume(const uint8_t *samples, size_t byte_count,
                            uint32_t center_hz, uint32_t sample_rate, uint32_t sequence);
