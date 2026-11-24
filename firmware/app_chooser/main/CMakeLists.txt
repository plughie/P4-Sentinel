idf_component_register(
    SRCS "chooser.c"
    PRIV_INCLUDE_DIRS "."
    PRIV_REQUIRES app_slots esp_driver_usb_serial_jtag nvs_flash
)
