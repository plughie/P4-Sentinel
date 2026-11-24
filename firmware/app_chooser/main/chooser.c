#include <stdio.h>
#include <string.h>

#include "app_slots.h"
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

enum { LINE_SIZE = 128 };

void app_main(void)
{
    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 4096, .rx_buffer_size = 256};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    usb_serial_jtag_vfs_use_driver();
    ESP_ERROR_CHECK(app_slots_init());
    app_slots_set_running_app("chooser");
    app_slots_announce("chooser");

    for (;;) {
        app_slots_poll();
        if (app_slots_back_pending()) {
            const uint32_t request = app_slots_take_back_request();
            app_slots_report("chooser", request);
        }
        char line[LINE_SIZE];
        while (app_slots_next_command(line, sizeof(line))) {
            if (!app_slots_parse_command(line, "chooser")) continue;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
}
