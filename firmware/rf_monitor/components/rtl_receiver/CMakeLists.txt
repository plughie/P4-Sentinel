# Build the locally supplied, separately licensed receiver component.
set(receiver "$ENV{RTL_SDR_SOURCE}")
if(NOT EXISTS "${receiver}/include/esp_rtl_sdr.h")
    message(FATAL_ERROR "Set RTL_SDR_SOURCE to the esp-rtl-sdr checkout")
endif()

idf_component_register(
    SRCS "${receiver}/src/esp_rtl_sdr.cpp"
         "${receiver}/src/esp_rtl_sdr_policy.cpp"
         "${receiver}/src/esp_rtl_sdr_multi.cpp"
    INCLUDE_DIRS "${receiver}/include"
    PRIV_INCLUDE_DIRS "${receiver}/private"
    REQUIRES log esp_timer freertos usb
)
target_compile_options(${COMPONENT_LIB} PRIVATE "$<$<COMPILE_LANGUAGE:CXX>:-std=gnu++17>")
