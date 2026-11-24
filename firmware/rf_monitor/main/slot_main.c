#include <stdio.h>
#include <stdbool.h>

#include "app_slots.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "rf_iq_pipeline.h"

esp_err_t rf_enter(void);
esp_err_t rf_leave(void);
void rf_command(const char *line);
void rf_idle(void);
bool rf_iq_capture_active(void);

void app_main(void)
{
    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 4096, .rx_buffer_size = 256};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    usb_serial_jtag_vfs_use_driver();
    ESP_ERROR_CHECK(app_slots_init());
    app_slots_set_running_app("rf");
    ESP_ERROR_CHECK(rf_enter());
    app_slots_announce("rf");

    for (;;) {
        app_slots_poll();
        if (app_slots_back_pending()) {
            const esp_err_t cleanup = rf_leave();
            if (cleanup == ESP_OK) {
                (void)app_slots_switch("chooser", app_slots_take_back_request());
            } else {
                printf("@APP {\"type\":\"error\",\"code\":%d}\n", cleanup);
                fflush(stdout);
            }
        }
        char line[512];
        while (!app_slots_back_pending() && app_slots_next_command(line, sizeof(line))) {
            if (!app_slots_parse_command(line, "rf")) rf_command(line);
        }
        rf_idle();
        vTaskDelay(pdMS_TO_TICKS(rf_iq_capture_active() ? 1 : 5));
    }
}
