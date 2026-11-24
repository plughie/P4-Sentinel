idf_component_register(SRCS "scanner.c" "slot_main.c" PRIV_REQUIRES app_slots bt esp_driver_usb_serial_jtag esp_event esp_netif esp_wifi nvs_flash)
target_compile_definitions(${COMPONENT_LIB} PRIVATE APP_SLOT_IMAGE=1)
