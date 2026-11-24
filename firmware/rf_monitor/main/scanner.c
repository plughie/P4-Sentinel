#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_hosted.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "app_slots.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/ble_hs_adv.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"

#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
#include <stdatomic.h>
#include "apps.h"
#endif

static bool cancellation_requested(void)
{
#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
    return apps_back_requested();
#else
    return false;
#endif
}

static void report_error(const char *radio, int code)
{
    printf("{\"type\":\"scan_error\",\"radio\":\"%s\",\"code\":%d}\n", radio, code);
}

static esp_err_t init_wifi(void)
{
    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&init), "scanner", "Wi-Fi init");
    ESP_RETURN_ON_ERROR(esp_wifi_set_storage(WIFI_STORAGE_RAM), "scanner", "Wi-Fi storage");
    return esp_wifi_set_mode(WIFI_MODE_STA);
}

static bool wifi_running;

static const char *wifi_auth_name(wifi_auth_mode_t mode)
{
    switch (mode) {
    case WIFI_AUTH_OPEN: return "Open";
    case WIFI_AUTH_WEP: return "WEP";
    case WIFI_AUTH_WPA_PSK: return "WPA-Personal";
    case WIFI_AUTH_WPA2_PSK: return "WPA2-Personal";
    case WIFI_AUTH_WPA_WPA2_PSK: return "WPA/WPA2-Personal";
    case WIFI_AUTH_ENTERPRISE: return "WPA2-Enterprise";
    case WIFI_AUTH_WPA3_PSK: return "WPA3-Personal";
    case WIFI_AUTH_WPA2_WPA3_PSK: return "WPA2/WPA3-Personal";
    case WIFI_AUTH_WAPI_PSK: return "WAPI-Personal";
    case WIFI_AUTH_OWE: return "Enhanced Open (OWE)";
    case WIFI_AUTH_WPA3_ENT_192: return "WPA3-Enterprise 192-bit";
    case WIFI_AUTH_DPP: return "DPP";
    case WIFI_AUTH_WPA3_ENTERPRISE: return "WPA3-Enterprise";
    case WIFI_AUTH_WPA2_WPA3_ENTERPRISE: return "WPA2/WPA3-Enterprise";
    case WIFI_AUTH_WPA_ENTERPRISE: return "WPA-Enterprise";
    case WIFI_AUTH_UNKNOWN: return "Unknown or unparsed";
    default: return "Unavailable";
    }
}

static const char *wifi_cipher_name(wifi_cipher_type_t cipher)
{
    switch (cipher) {
    case WIFI_CIPHER_TYPE_NONE: return "None";
    case WIFI_CIPHER_TYPE_WEP40: return "WEP-40";
    case WIFI_CIPHER_TYPE_WEP104: return "WEP-104";
    case WIFI_CIPHER_TYPE_TKIP: return "TKIP";
    case WIFI_CIPHER_TYPE_CCMP: return "CCMP (AES)";
    case WIFI_CIPHER_TYPE_TKIP_CCMP: return "TKIP/CCMP";
    case WIFI_CIPHER_TYPE_AES_CMAC128: return "AES-CMAC-128";
    case WIFI_CIPHER_TYPE_SMS4: return "SMS4";
    case WIFI_CIPHER_TYPE_GCMP: return "GCMP";
    case WIFI_CIPHER_TYPE_GCMP256: return "GCMP-256";
    case WIFI_CIPHER_TYPE_AES_GMAC128: return "AES-GMAC-128";
    case WIFI_CIPHER_TYPE_AES_GMAC256: return "AES-GMAC-256";
    case WIFI_CIPHER_TYPE_UNKNOWN: return "Unknown or unparsed";
    default: return "Unavailable";
    }
}

static const char *wifi_bandwidth_name(wifi_bandwidth_t bandwidth)
{
    switch (bandwidth) {
    case WIFI_BW20: return "20 MHz";
    case WIFI_BW40: return "40 MHz";
    case WIFI_BW80: return "80 MHz";
    case WIFI_BW160: return "160 MHz";
    case WIFI_BW80_BW80: return "80+80 MHz";
    default: return "Unavailable";
    }
}

static const char *wifi_secondary_channel_name(wifi_second_chan_t channel)
{
    switch (channel) {
    case WIFI_SECOND_CHAN_NONE: return "None";
    case WIFI_SECOND_CHAN_ABOVE: return "Above primary";
    case WIFI_SECOND_CHAN_BELOW: return "Below primary";
    default: return "Unavailable";
    }
}

static void print_wifi_standards(const wifi_ap_record_t *ap)
{
    bool comma = false;
#define PRINT_WIFI_STANDARD(flag, label) do { \
    if (ap->flag) { \
        printf("%s\"%s\"", comma ? "," : "", label); \
        comma = true; \
    } \
} while (0)
    PRINT_WIFI_STANDARD(phy_11b, "802.11b");
    PRINT_WIFI_STANDARD(phy_11g, "802.11g");
    PRINT_WIFI_STANDARD(phy_11n, "802.11n");
    PRINT_WIFI_STANDARD(phy_11a, "802.11a");
    PRINT_WIFI_STANDARD(phy_11ac, "802.11ac");
    PRINT_WIFI_STANDARD(phy_11ax, "802.11ax");
    PRINT_WIFI_STANDARD(phy_lr, "ESP-NOW LR");
#undef PRINT_WIFI_STANDARD
}

static esp_err_t stop_wifi(void)
{
    if (!wifi_running) return ESP_OK;
    esp_err_t result = esp_wifi_stop();
    if (result == ESP_OK || result == ESP_ERR_WIFI_NOT_STARTED) {
        wifi_running = false;
        return ESP_OK;
    }
    return result;
}

#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
static void wifi_scan_done(void *arg, esp_event_base_t base, int32_t id, void *event)
{
    xSemaphoreGive((SemaphoreHandle_t)arg);
}

static esp_err_t start_wifi_scan(wifi_scan_config_t *scan)
{
    SemaphoreHandle_t done = xSemaphoreCreateBinary();
    if (!done) return ESP_ERR_NO_MEM;
    esp_event_handler_instance_t handler;
    esp_err_t result = esp_event_handler_instance_register(
        WIFI_EVENT, WIFI_EVENT_SCAN_DONE, wifi_scan_done, done, &handler);
    if (result == ESP_OK) {
        result = esp_wifi_scan_start(scan, false);
        if (result == ESP_OK) {
            const TickType_t start = xTaskGetTickCount();
            while (true) {
                if (cancellation_requested()) {
                    (void)esp_wifi_scan_stop();
                    result = ESP_ERR_INVALID_STATE;
                    break;
                }
                if (xSemaphoreTake(done, pdMS_TO_TICKS(25)) == pdTRUE) break;
                if (xTaskGetTickCount() - start >= pdMS_TO_TICKS(8000)) {
                    (void)esp_wifi_scan_stop();
                    result = ESP_ERR_TIMEOUT;
                    break;
                }
            }
        }
        esp_event_handler_instance_unregister(WIFI_EVENT, WIFI_EVENT_SCAN_DONE, handler);
    }
    vSemaphoreDelete(done);
    return result;
}
#else
static esp_err_t start_wifi_scan(wifi_scan_config_t *scan)
{
    return esp_wifi_scan_start(scan, true);
}
#endif

static esp_err_t scan_wifi(void)
{
    ESP_RETURN_ON_ERROR(esp_wifi_start(), "scanner", "Wi-Fi start");
    wifi_running = true;

    wifi_scan_config_t scan = {
        .show_hidden = true,
        .scan_type = WIFI_SCAN_TYPE_PASSIVE,
        .scan_time.passive = 150,
    };
    uint16_t count = 0;
    esp_err_t result = cancellation_requested() ? ESP_ERR_INVALID_STATE : start_wifi_scan(&scan);
    if (result == ESP_OK && !cancellation_requested()) {
        wifi_ap_record_t *records = NULL;
        result = esp_wifi_scan_get_ap_num(&count);
        if (result == ESP_OK && count > 0) {
            // Older C6 firmware exposes only the bulk scan results RPC.
            count = count > 64 ? 64 : count;
            records = calloc(count, sizeof(*records));
            result = records ? esp_wifi_scan_get_ap_records(&count, records) : ESP_ERR_NO_MEM;
        }
        for (uint16_t index = 0; result == ESP_OK && index < count && !cancellation_requested(); ++index) {
            const wifi_ap_record_t *ap = &records[index];
            printf("{\"type\":\"wifi_ap\",\"bssid\":\"%02x:%02x:%02x:%02x:%02x:%02x\","
                   "\"channel\":%u,\"rssi\":%d,\"ssid_hex\":\"",
                   ap->bssid[0], ap->bssid[1], ap->bssid[2],
                   ap->bssid[3], ap->bssid[4], ap->bssid[5], ap->primary, ap->rssi);
            size_t ssid_length = strnlen((const char *)ap->ssid, sizeof(ap->ssid));
            for (size_t byte = 0; byte < ssid_length; ++byte) {
                printf("%02x", ap->ssid[byte]);
            }
            printf("\",\"auth_mode\":\"%s\",\"pairwise_cipher\":\"%s\","
                   "\"group_cipher\":\"%s\",\"channel_width\":\"%s\","
                   "\"secondary_channel\":\"%s\",\"wps\":%s,\"supported_standards\":[",
                   wifi_auth_name(ap->authmode), wifi_cipher_name(ap->pairwise_cipher),
                   wifi_cipher_name(ap->group_cipher), wifi_bandwidth_name(ap->bandwidth),
                   wifi_secondary_channel_name(ap->second), ap->wps ? "true" : "false");
            print_wifi_standards(ap);
            puts("],\"raw_information_elements_available\":false}");
        }
        free(records);
        esp_wifi_clear_ap_list();
    }
    esp_err_t stop_result = stop_wifi();
    if (result == ESP_OK && stop_result == ESP_OK && !cancellation_requested()) {
        printf("{\"type\":\"scan_complete\",\"radio\":\"wifi\",\"count\":%u}\n", count);
    }
    return result == ESP_OK ? stop_result : result;
}

typedef struct {
    ble_addr_t address;
    int8_t rssi;
    uint8_t name_len;
    uint8_t name[31];
    uint8_t advertisement_len;
    uint8_t advertisement[BLE_HS_ADV_MAX_SZ];
    bool advertisement_truncated;
} advertisement_t;

enum { ADVERTISEMENT_CAPACITY = 128 };
static advertisement_t *advertisements;
static size_t advertisement_count;
static bool validation_target_address_seen;
static bool validation_target_name_seen;
static int8_t validation_target_rssi;
static int ble_scan_result;
static SemaphoreHandle_t ble_scan_done;
static SemaphoreHandle_t ble_host_synced;
static SemaphoreHandle_t ble_capture_lock;
static bool ble_scan_pending;
static bool ble_accept_reports;

// BLE stores address octets least-significant first in ble_addr_t.val.
static const uint8_t validation_target_address[6] = {0xe1, 0xcf, 0xbe, 0xe9, 0x0f, 0x00};
static const char validation_target_name[] = "wd-22_cfe1";

static bool name_matches(const uint8_t *name, uint8_t length)
{
    if (length != sizeof(validation_target_name) - 1) {
        return false;
    }
    for (size_t index = 0; index < length; ++index) {
        uint8_t byte = name[index];
        char expected = validation_target_name[index];
        if (byte >= 'A' && byte <= 'Z') {
            byte = (uint8_t)(byte - 'A' + 'a');
        }
        if (expected >= 'A' && expected <= 'Z') {
            expected = (char)(expected - 'A' + 'a');
        }
        if (byte != (uint8_t)expected) {
            return false;
        }
    }
    return true;
}

static int ble_event(struct ble_gap_event *event, void *arg)
{
    if (event->type == BLE_GAP_EVENT_DISC) {
        xSemaphoreTake(ble_capture_lock, portMAX_DELAY);
        if (!ble_accept_reports) {
            xSemaphoreGive(ble_capture_lock);
            return 0;
        }
        const struct ble_gap_disc_desc *report = &event->disc;
        struct ble_hs_adv_fields fields = {0};
        advertisement_t advertisement = {.address = report->addr, .rssi = report->rssi};
        advertisement.advertisement_len = report->length_data;
        if (advertisement.advertisement_len > sizeof(advertisement.advertisement)) {
            advertisement.advertisement_len = sizeof(advertisement.advertisement);
            advertisement.advertisement_truncated = true;
        }
        memcpy(advertisement.advertisement, report->data, advertisement.advertisement_len);
        if (ble_hs_adv_parse_fields(&fields, report->data, report->length_data) == 0 && fields.name) {
            advertisement.name_len = fields.name_len;
            if (advertisement.name_len > sizeof(advertisement.name)) {
                advertisement.name_len = sizeof(advertisement.name);
            }
            memcpy(advertisement.name, fields.name, advertisement.name_len);
        }
        if (memcmp(report->addr.val, validation_target_address, sizeof(validation_target_address)) == 0) {
            validation_target_address_seen = true;
            validation_target_rssi = report->rssi;
        }
        if (name_matches(advertisement.name, advertisement.name_len)) {
            validation_target_name_seen = true;
            validation_target_rssi = report->rssi;
        }
        if (advertisement_count < ADVERTISEMENT_CAPACITY) {
            advertisements[advertisement_count++] = advertisement;
        }
        xSemaphoreGive(ble_capture_lock);
    } else if (event->type == BLE_GAP_EVENT_DISC_COMPLETE) {
        ble_scan_result = event->disc_complete.reason;
        xSemaphoreGive(ble_scan_done);
    }
    return 0;
}

static void report_ble_results(void)
{
    for (size_t index = 0; index < advertisement_count; ++index) {
        if (cancellation_requested()) return;
        const advertisement_t *report = &advertisements[index];
        const uint8_t *address = report->address.val;
        printf("{\"type\":\"ble_advertisement\",\"address\":\"%02x:%02x:%02x:%02x:%02x:%02x\","
               "\"address_type\":%u,\"rssi\":%d,\"name_hex\":\"",
               address[5], address[4], address[3], address[2], address[1], address[0],
               report->address.type, report->rssi);
        for (size_t byte = 0; byte < report->name_len; ++byte) {
            printf("%02x", report->name[byte]);
        }
        printf("\",\"adv_hex\":\"");
        for (size_t byte = 0; byte < report->advertisement_len; ++byte) {
            printf("%02x", report->advertisement[byte]);
        }
        printf("\",\"adv_truncated\":%s}\n",
               report->advertisement_truncated ? "true" : "false");
    }
    bool target_seen = validation_target_address_seen || validation_target_name_seen;
    printf("{\"type\":\"ble_target_check\",\"name\":\"%s\",\"address\":\"00:0f:e9:be:cf:e1\","
           "\"seen\":%s,\"address_seen\":%s,\"name_seen\":%s,\"rssi\":%d}\n",
           validation_target_name, target_seen ? "true" : "false",
           validation_target_address_seen ? "true" : "false",
           validation_target_name_seen ? "true" : "false",
           target_seen ? validation_target_rssi : 0);
    puts("{\"type\":\"scan_complete\",\"radio\":\"ble\"}");
}

static void set_ble_report_delivery(bool accept)
{
    xSemaphoreTake(ble_capture_lock, portMAX_DELAY);
    ble_accept_reports = accept;
    xSemaphoreGive(ble_capture_lock);
}

static int scan_ble(void)
{
    // A scan that timed out may still deliver a completion on the host task.
    if (ble_scan_pending) {
        if (xSemaphoreTake(ble_scan_done, 0) != pdTRUE) {
            return ESP_ERR_INVALID_STATE;
        }
        ble_scan_pending = false;
    }
    if (!ble_hs_synced()) {
        return ESP_ERR_INVALID_STATE;
    }
    advertisement_count = 0;
    validation_target_address_seen = false;
    validation_target_name_seen = false;
    uint8_t address_type;
    int result = ble_hs_id_infer_auto(0, &address_type);
    if (result == 0) {
        set_ble_report_delivery(true);
        struct ble_gap_disc_params scan = {
            .passive = 1,
            .filter_duplicates = 1,
        };
        result = ble_gap_disc(address_type, 5000, &scan, ble_event, NULL);
    }
    if (result != 0) {
        set_ble_report_delivery(false);
        return result;
    }
    const TickType_t start = xTaskGetTickCount();
    while (xSemaphoreTake(ble_scan_done, pdMS_TO_TICKS(25)) != pdTRUE) {
        if (cancellation_requested()) {
            set_ble_report_delivery(false);
            const int cancel = ble_gap_disc_cancel();
            if (cancel != 0) {
                // EALREADY can mean the natural completion callback is still in flight.
                ble_scan_pending = xSemaphoreTake(ble_scan_done, pdMS_TO_TICKS(100)) != pdTRUE;
            }
            return ESP_ERR_INVALID_STATE;
        }
        if (xTaskGetTickCount() - start >= pdMS_TO_TICKS(15000)) {
            set_ble_report_delivery(false);
            ble_scan_pending = true;
            return ESP_ERR_TIMEOUT;
        }
    }
    set_ble_report_delivery(false);
    if (ble_scan_result == 0 && !cancellation_requested()) {
        report_ble_results();
    }
    return ble_scan_result;
}

static void ble_ready(void)
{
    xSemaphoreGive(ble_host_synced);
}

static void ble_reset(int reason)
{
    ESP_LOGW("scanner", "NimBLE host reset: %d", reason);
}

static void ble_host_task(void *arg)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static esp_err_t init_ble(void)
{
    esp_err_t result;
    esp_hosted_coprocessor_fwver_t version = {0};
    const esp_err_t version_result = esp_hosted_get_coprocessor_fwversion(&version);
    if (version_result == ESP_OK) {
        ESP_LOGI("scanner", "C6 version query returned %" PRIu32 ".%" PRIu32 ".%" PRIu32,
                 version.major1, version.minor1, version.patch1);
    } else {
        ESP_LOGW("scanner", "C6 version query failed: %s (%d)", esp_err_to_name(version_result), version_result);
    }
    // Older ESP-Hosted firmware starts its Bluetooth controller at boot.
    // The stock bench C6 advertises SDIO HCI but does not answer either newer RPC.
    const bool legacy_boot_controller = version_result != ESP_OK ||
        version.major1 < 2 ||
        (version.major1 == 2 && (version.minor1 < 5 ||
                                (version.minor1 == 5 && version.patch1 < 2)));
    result = ESP_OK;
    if (legacy_boot_controller) {
        ESP_LOGI("scanner", "Trying boot-started C6 Bluetooth controller");
    } else {
        ESP_LOGI("scanner", "Initializing C6 Bluetooth controller");
        result = esp_hosted_bt_controller_init();
        if (result == ESP_OK) {
            ESP_LOGI("scanner", "Enabling C6 Bluetooth controller");
            result = esp_hosted_bt_controller_enable();
        }
    }
    if (result == ESP_OK) {
        ESP_LOGI("scanner", "Starting P4 NimBLE host");
        result = nimble_port_init();
    }
    if (result != ESP_OK) {
        return result;
    }
    ble_scan_done = xSemaphoreCreateBinary();
    ble_host_synced = xSemaphoreCreateBinary();
    ble_capture_lock = xSemaphoreCreateMutex();
    if (!ble_scan_done || !ble_host_synced || !ble_capture_lock) {
        return ESP_ERR_NO_MEM;
    }
    ble_hs_cfg.sync_cb = ble_ready;
    ble_hs_cfg.reset_cb = ble_reset;
    nimble_port_freertos_init(ble_host_task);
    return xSemaphoreTake(ble_host_synced, pdMS_TO_TICKS(15000)) == pdTRUE
        ? ESP_OK : ESP_ERR_TIMEOUT;
}

static void run_scan(const char *radio, int init_result, int (*scan)(void))
{
    printf("{\"type\":\"scan_start\",\"radio\":\"%s\"}\n", radio);
    int result = init_result == ESP_OK ? scan() : init_result;
    if (result != ESP_OK && !cancellation_requested()) {
        report_error(radio, result);
    }
    fflush(stdout);
}

static int wifi_init_result;
static int ble_init_result;
#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
static atomic_bool initialized;
static bool platform_started;
static bool ready_pending;
#else
static bool initialized;
#endif

static void initialize_radios(void)
{
    const esp_err_t hosted = esp_hosted_connect_to_slave();
    wifi_init_result = hosted == ESP_OK ? init_wifi() : hosted;
    ble_init_result = hosted == ESP_OK ? init_ble() : hosted;
    initialized = true;
}

#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
static void start_platform(void *arg)
{
    initialize_radios();
    vTaskDelete(NULL);
}
#endif

esp_err_t network_enter(void)
{
    if (advertisements) {
        return ESP_OK;
    }
    advertisements = calloc(ADVERTISEMENT_CAPACITY, sizeof(*advertisements));
    if (!advertisements) {
        return ESP_ERR_NO_MEM;
    }
#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
    if (!platform_started) {
        if (xTaskCreate(start_platform, "scanner_init", 6144, NULL, 5, NULL) != pdPASS) {
            free(advertisements);
            advertisements = NULL;
            return ESP_ERR_NO_MEM;
        }
        platform_started = true;
    }
#else
    if (!initialized) initialize_radios();
#endif
    return ESP_OK;
}

#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
esp_err_t network_leave(void)
{
    ready_pending = false;
    esp_err_t result = stop_wifi();
    if (result != ESP_OK) return result;
    // Never release the capture buffer while a late NimBLE callback can use it.
    if (ble_scan_pending) {
        if (xSemaphoreTake(ble_scan_done, 0) != pdTRUE) {
            return ESP_ERR_TIMEOUT;
        }
        ble_scan_pending = false;
    }
    free(advertisements);
    advertisements = NULL;
    return ESP_OK;
}

void network_idle(void)
{
    if (ready_pending && initialized) {
        ready_pending = false;
        network_command("status");
    }
}
#endif

void network_command(const char *line)
{
#if defined(APP_CHOOSER) || defined(APP_SLOT_IMAGE)
    if (!initialized) {
        if (strcmp(line, "status") == 0) ready_pending = true;
        return;
    }
#endif
    if (strcmp(line, "status") == 0) {
        puts("{\"type\":\"scanner_ready\"}");
        fflush(stdout);
    } else if (strcmp(line, "scan wifi") == 0) {
        run_scan("wifi", wifi_init_result, scan_wifi);
    } else if (strcmp(line, "scan ble") == 0) {
        run_scan("ble", ble_init_result, scan_ble);
    }
}

#if !defined(APP_CHOOSER) && !defined(APP_SLOT_IMAGE)
static void read_commands(void)
{
    char line[128];
    size_t length = 0;
    bool overflow = false;
    for (;;) {
        uint8_t byte;
        if (usb_serial_jtag_read_bytes(&byte, 1, portMAX_DELAY) != 1) {
            continue;
        }
        if (byte == '\r') {
            continue;
        }
        if (byte != '\n') {
            if (length < sizeof(line) - 1) {
                line[length++] = (char)byte;
            } else {
                overflow = true;
            }
            continue;
        }
        line[length] = '\0';
        if (!overflow && !app_slots_parse_command(line, "network")) network_command(line);
        length = 0;
        overflow = false;
    }
}

void app_main(void)
{
    usb_serial_jtag_driver_config_t usb = {.tx_buffer_size = 4096, .rx_buffer_size = 256};
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
    usb_serial_jtag_vfs_use_driver();
    ESP_ERROR_CHECK(app_slots_init());
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(network_enter());
    app_slots_announce("network");
    network_command("scan wifi");
    network_command("scan ble");
    read_commands();
}
#endif
