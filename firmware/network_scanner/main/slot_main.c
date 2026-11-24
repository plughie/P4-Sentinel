#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "app_slots.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

esp_err_t network_enter(void);
esp_err_t network_leave(void);
void network_command(const char *line);
void network_idle(void);

void app_main(void)
{
    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 4096, .rx_buffer_size = 256};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    usb_serial_jtag_vfs_use_driver();
    ESP_ERROR_CHECK(app_slots_init());
    app_slots_set_running_app("network");
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(network_enter());
    app_slots_announce("network");

    for (;;) {
        app_slots_poll();
        if (app_slots_back_pending()) {
            const esp_err_t cleanup = network_leave();
            if (cleanup == ESP_OK) {
                (void)app_slots_switch("chooser", app_slots_take_back_request());
            } else {
                printf("@APP {\"type\":\"error\",\"code\":%d}\n", cleanup);
                fflush(stdout);
            }
        }
        char line[512];
        while (!app_slots_back_pending() && app_slots_next_command(line, sizeof(line))) {
            if (!app_slots_parse_command(line, "network")) network_command(line);
        }
        network_idle();
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
