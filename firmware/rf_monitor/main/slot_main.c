#include <stdio.h>
#include <string.h>

#include "app_slots.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "rf_iq_pipeline.h"

esp_err_t network_enter(void);
esp_err_t network_leave(void);
void network_command(const char *line);
void network_idle(void);
esp_err_t rf_enter(void);
esp_err_t rf_leave(void);
void rf_command(const char *line);
void rf_idle(void);
bool rf_iq_capture_active(void);

typedef enum { MODE_MENU, MODE_NETWORK, MODE_RF } sentinel_mode_t;

static sentinel_mode_t mode_from_scene(const char *scene)
{
    if (strcmp(scene, "network") == 0) return MODE_NETWORK;
    if (strcmp(scene, "rf") == 0) return MODE_RF;
    return MODE_MENU;
}

static const char *scene_from_mode(sentinel_mode_t mode)
{
    return mode == MODE_NETWORK ? "network" : mode == MODE_RF ? "rf" : "sentinel";
}

static esp_err_t clean_mode(sentinel_mode_t mode)
{
    esp_err_t result = ESP_OK;
    if (mode == MODE_NETWORK) result = network_leave();
    if (mode == MODE_RF) result = rf_leave();
    return result;
}

void app_main(void)
{
    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 4096, .rx_buffer_size = 256};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    usb_serial_jtag_vfs_use_driver();
    ESP_ERROR_CHECK(app_slots_init());
    app_slots_set_running_app("sentinel");

    sentinel_mode_t mode = mode_from_scene(app_slots_boot_scene());
    if (mode == MODE_NETWORK) {
        ESP_ERROR_CHECK(esp_netif_init());
        ESP_ERROR_CHECK(esp_event_loop_create_default());
        ESP_ERROR_CHECK(network_enter());
    } else if (mode == MODE_RF) {
        ESP_ERROR_CHECK(rf_enter());
    }
    app_slots_set_running_app(scene_from_mode(mode));
    app_slots_announce(scene_from_mode(mode));

    for (;;) {
        app_slots_poll();
        if (app_slots_back_pending()) {
            const esp_err_t cleanup = clean_mode(mode);
            if (cleanup == ESP_OK) {
                (void)app_slots_switch("chooser", app_slots_take_back_request());
            } else {
                printf("@APP {\"type\":\"error\",\"code\":%d}\n", cleanup);
                fflush(stdout);
            }
        }

        char line[512];
        while (!app_slots_back_pending() && !app_slots_mode_pending()
               && app_slots_next_command(line, sizeof(line))) {
            if (app_slots_parse_command(line, scene_from_mode(mode))) continue;
            if (mode == MODE_NETWORK) network_command(line);
            if (mode == MODE_RF) rf_command(line);
        }
        if (app_slots_mode_pending()) {
            const esp_err_t cleanup = clean_mode(mode);
            if (cleanup == ESP_OK) {
                (void)app_slots_switch_mode();
            } else {
                app_slots_cancel_mode();
                printf("@APP {\"type\":\"error\",\"code\":%d}\n", cleanup);
                fflush(stdout);
            }
        }
        if (mode == MODE_NETWORK) network_idle();
        if (mode == MODE_RF) rf_idle();
        vTaskDelay(pdMS_TO_TICKS(mode == MODE_RF && rf_iq_capture_active() ? 1 : 5));
    }
}
