#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

typedef void (*rf_storage_faa_match_callback_t)(const char *address, const char *registration,
                                                 const char *year, const char *aircraft_type,
                                                 const char *last_action_date);

esp_err_t rf_storage_init(void);
void rf_storage_end_session(void);
void rf_storage_record_event(const char *line, size_t length);
void rf_storage_set_logging(bool enabled);
bool rf_storage_is_mounted(void);
bool rf_storage_is_logging(void);
uint64_t rf_storage_capacity_bytes(void);
uint64_t rf_storage_free_bytes(void);
bool rf_storage_faa_master_present(void);
esp_err_t rf_storage_export_adsb_csv(uint32_t *rows, char *path, size_t path_size);
esp_err_t rf_storage_match_faa_master(const char *addresses,
                                      rf_storage_faa_match_callback_t callback,
                                      uint32_t *matches);
const char *rf_storage_last_error(void);
