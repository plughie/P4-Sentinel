idf_component_register(SRCS "monitor.c" "slot_main.c" "rf_storage.c" "rf_iq_pipeline.c" "adsb_decoder.c" "tetra_detector.c" "p25_decoder.c" "pocsag_decoder.c" "fm_audio.c" "tpms_decoder.c" "frequency_finder.c" PRIV_REQUIRES app_slots
    fatfs rtl_receiver esp_driver_gpio esp_driver_sdmmc esp_driver_usb_serial_jtag esp_timer nvs_flash sdmmc)
target_compile_definitions(${COMPONENT_LIB} PRIVATE APP_SLOT_IMAGE=1)
