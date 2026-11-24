#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

esp_err_t app_slots_init(void);
void app_slots_set_running_app(const char *app);
void app_slots_poll(void);
bool app_slots_next_command(char *line, size_t capacity);
bool app_slots_back_pending(void);
uint32_t app_slots_take_back_request(void);
bool apps_back_requested(void);
void app_slots_report(const char *app, uint32_t request);
void app_slots_announce(const char *app);
const char *app_slots_boot_scene(void);
bool app_slots_mode_pending(void);
void app_slots_cancel_mode(void);
esp_err_t app_slots_switch_mode(void);
bool app_slots_parse_command(const char *line, const char *running_app);
esp_err_t app_slots_switch(const char *app, uint32_t request);
