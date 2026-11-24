#pragma once

#include <stdbool.h>
#include "esp_err.h"

bool apps_back_requested(void);

esp_err_t network_enter(void);
esp_err_t network_leave(void);
void network_command(const char *line);
void network_idle(void);

esp_err_t rf_enter(void);
esp_err_t rf_leave(void);
void rf_command(const char *line);
void rf_idle(void);
bool rf_iq_capture_active(void);
