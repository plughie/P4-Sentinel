#include "app_slots.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "driver/usb_serial_jtag.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "nvs.h"
#include "nvs_flash.h"

enum { SLOT_LINE_SIZE = 512, SLOT_QUEUE_SIZE = 8 };
static const char *NS = "app_slots";
static char running_app[16] = "chooser";
static char input_line[SLOT_LINE_SIZE];
static char command_queue[SLOT_QUEUE_SIZE][SLOT_LINE_SIZE];
static size_t input_length;
static size_t queue_read, queue_count;
static bool input_overflow, back_pending;
static uint32_t back_request;
static uint8_t installed_apps;
static uint8_t default_scene;
static char boot_scene[16] = "sentinel";
static bool mode_pending;
static char pending_mode[16];
static uint32_t mode_request;

enum {
    APP_INSTALLED_SENTINEL = 1u << 0,
    APP_INSTALLED_CONTROLLER = 1u << 1,
};

esp_err_t app_slots_init(void)
{
    esp_err_t result = nvs_flash_init();
    if (result != ESP_OK) return result;
    const esp_partition_t *manifest = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, "app_manifest");
    if (!manifest) return ESP_ERR_NOT_FOUND;
    uint8_t header[8];
    result = esp_partition_read(manifest, 0, header, sizeof(header));
    if (result != ESP_OK) return result;
    if (memcmp(header, "P4S1", 4) != 0 || header[4] != 1) return ESP_ERR_INVALID_RESPONSE;
    installed_apps = header[5];
    default_scene = header[6];
    return ESP_OK;
}

void app_slots_set_running_app(const char *app)
{
    snprintf(running_app, sizeof(running_app), "%s", app);
}

static uint32_t parse_request(const char *value)
{
    while (*value == ' ') ++value;
    if (!*value) return 0;
    char *end;
    const unsigned long request = strtoul(value, &end, 10);
    return (*end == '\0' && request <= UINT32_MAX) ? (uint32_t)request : 0;
}

void app_slots_report(const char *app, uint32_t request)
{
    if (strcmp(app, "chooser") == 0) {
        printf("@APP {\"type\":\"scene\",\"app\":\"chooser\",\"request\":%" PRIu32
               ",\"installed\":{\"sentinel\":%s,\"controller\":%s}}\n",
               request, (installed_apps & APP_INSTALLED_SENTINEL) ? "true" : "false",
               (installed_apps & APP_INSTALLED_CONTROLLER) ? "true" : "false");
    } else {
        printf("@APP {\"type\":\"scene\",\"app\":\"%s\",\"request\":%" PRIu32 "}\n",
               app, request);
    }
    fflush(stdout);
}

static esp_err_t persist_request(const char *app, uint32_t request)
{
    nvs_handle_t handle;
    esp_err_t result = nvs_open(NS, NVS_READWRITE, &handle);
    if (result != ESP_OK) return result;
    result = nvs_set_str(handle, "target", app);
    if (result == ESP_OK) result = nvs_set_u32(handle, "request", request);
    if (result == ESP_OK) result = nvs_commit(handle);
    nvs_close(handle);
    return result;
}

static uint32_t take_request(const char *app)
{
    nvs_handle_t handle;
    if (nvs_open(NS, NVS_READWRITE, &handle) != ESP_OK) return 0;
    uint32_t request = 0;
    char target[16] = {0};
    size_t length = sizeof(target);
    if (nvs_get_str(handle, "target", target, &length) == ESP_OK && strcmp(target, app) == 0) {
        (void)nvs_get_u32(handle, "request", &request);
    }
    (void)nvs_erase_key(handle, "target");
    (void)nvs_erase_key(handle, "request");
    (void)nvs_commit(handle);
    nvs_close(handle);
    return request;
}

const char *app_slots_boot_scene(void)
{
    nvs_handle_t handle;
    if (nvs_open(NS, NVS_READONLY, &handle) == ESP_OK) {
        char target[16] = {0};
        size_t length = sizeof(target);
        if (nvs_get_str(handle, "target", target, &length) == ESP_OK) {
            nvs_close(handle);
            if (strcmp(target, "network") == 0 || strcmp(target, "rf") == 0
                || strcmp(target, "sentinel") == 0) {
                snprintf(boot_scene, sizeof(boot_scene), "%s", target);
                return boot_scene;
            }
        } else {
            nvs_close(handle);
        }
    }
    snprintf(boot_scene, sizeof(boot_scene), "%s",
             default_scene == 1 ? "network" : default_scene == 2 ? "rf" : "sentinel");
    return boot_scene;
}

bool app_slots_mode_pending(void)
{
    return mode_pending;
}

void app_slots_cancel_mode(void)
{
    mode_pending = false;
    pending_mode[0] = '\0';
    mode_request = 0;
}

esp_err_t app_slots_switch_mode(void)
{
    if (!mode_pending || (strcmp(pending_mode, "sentinel") != 0
        && strcmp(pending_mode, "network") != 0 && strcmp(pending_mode, "rf") != 0)) {
        return ESP_ERR_INVALID_STATE;
    }
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_APP_OTA_0, NULL);
    if (!partition) return ESP_ERR_NOT_FOUND;
    esp_err_t result = persist_request(pending_mode, mode_request);
    if (result != ESP_OK) return result;
    result = esp_ota_set_boot_partition(partition);
    if (result != ESP_OK) return result;
    printf("@APP {\"type\":\"switching\",\"app\":\"%s\",\"request\":%" PRIu32 "}\n",
           pending_mode, mode_request);
    fflush(stdout);
    esp_restart();
    return ESP_OK;
}

void app_slots_announce(const char *app)
{
    app_slots_report(app, take_request(app));
}

static const esp_partition_t *target_partition(const char *app)
{
    if (strcmp(app, "chooser") == 0) {
        return esp_partition_find_first(ESP_PARTITION_TYPE_APP,
                                        ESP_PARTITION_SUBTYPE_APP_FACTORY, NULL);
    }
    if (strcmp(app, "sentinel") == 0 && !(installed_apps & APP_INSTALLED_SENTINEL)) return NULL;
    if (strcmp(app, "controller") == 0 && !(installed_apps & APP_INSTALLED_CONTROLLER)) return NULL;
    if (strcmp(app, "sentinel") == 0 || strcmp(app, "controller") == 0) {
        const esp_partition_subtype_t subtype = strcmp(app, "sentinel") == 0
            ? ESP_PARTITION_SUBTYPE_APP_OTA_0 : ESP_PARTITION_SUBTYPE_APP_OTA_1;
        return esp_partition_find_first(ESP_PARTITION_TYPE_APP, subtype, NULL);
    }
    return NULL;
}

esp_err_t app_slots_switch(const char *app, uint32_t request)
{
    const esp_partition_t *partition = target_partition(app);
    if (!partition) return ESP_ERR_NOT_FOUND;
    esp_err_t result = persist_request(app, request);
    if (result != ESP_OK) return result;
    result = esp_ota_set_boot_partition(partition);
    if (result != ESP_OK) return result;
    printf("@APP {\"type\":\"switching\",\"app\":\"%s\",\"request\":%" PRIu32 "}\n",
           app, request);
    fflush(stdout);
    esp_restart();
    return ESP_OK;
}

static void process_input_line(void)
{
    input_line[input_length] = '\0';
    if (input_overflow || !input_length || back_pending) return;
    if (strncmp(input_line, "apps status", 11) == 0
        && (input_line[11] == '\0' || input_line[11] == ' ')) {
        app_slots_report(running_app, parse_request(input_line + 11));
    } else if (strncmp(input_line, "apps back", 9) == 0
               && (input_line[9] == '\0' || input_line[9] == ' ')) {
        back_request = parse_request(input_line + 9);
        back_pending = true;
        queue_count = 0;
        queue_read = 0;
    } else if (queue_count < SLOT_QUEUE_SIZE) {
        const size_t write_index = (queue_read + queue_count) % SLOT_QUEUE_SIZE;
        memcpy(command_queue[write_index], input_line, input_length + 1);
        ++queue_count;
    }
}

void app_slots_poll(void)
{
    uint8_t bytes[64];
    const int count = usb_serial_jtag_read_bytes(bytes, sizeof(bytes), 0);
    for (int index = 0; index < count; ++index) {
        const uint8_t byte = bytes[index];
        if (byte == '\r') continue;
        if (byte != '\n') {
            if (input_length < sizeof(input_line) - 1) input_line[input_length++] = (char)byte;
            else input_overflow = true;
            continue;
        }
        process_input_line();
        input_length = 0;
        input_overflow = false;
    }
}

bool apps_back_requested(void)
{
    app_slots_poll();
    char line[SLOT_LINE_SIZE];
    while (!back_pending && !mode_pending && app_slots_next_command(line, sizeof(line))) {
        (void)app_slots_parse_command(line, running_app);
    }
    return back_pending || mode_pending;
}

bool app_slots_back_pending(void)
{
    return back_pending;
}

uint32_t app_slots_take_back_request(void)
{
    const uint32_t request = back_request;
    back_pending = false;
    back_request = 0;
    return request;
}

bool app_slots_next_command(char *line, size_t capacity)
{
    if (!queue_count || capacity == 0) return false;
    snprintf(line, capacity, "%s", command_queue[queue_read]);
    queue_read = (queue_read + 1) % SLOT_QUEUE_SIZE;
    --queue_count;
    return true;
}

bool app_slots_parse_command(const char *line, const char *app)
{
    uint32_t request = 0;
    const char *value = NULL;
    if (strncmp(line, "apps status", 11) == 0
        && (line[11] == '\0' || line[11] == ' ')) {
        app_slots_report(app, parse_request(line + 11));
        return true;
    }
    if (strncmp(line, "apps back", 9) == 0
        && (line[9] == '\0' || line[9] == ' ')) {
        back_request = parse_request(line + 9);
        back_pending = true;
        return true;
    }
    if (strncmp(line, "apps mode ", 10) == 0) {
        const char *mode = line + 10;
        const char *space = strchr(mode, ' ');
        if (space) {
            char requested[16] = {0};
            const size_t length = (size_t)(space - mode);
            if (length < sizeof(requested)) {
                memcpy(requested, mode, length);
                if ((strcmp(requested, "sentinel") == 0 || strcmp(requested, "network") == 0
                     || strcmp(requested, "rf") == 0)
                    && (strcmp(running_app, "sentinel") == 0
                        || strcmp(running_app, "network") == 0 || strcmp(running_app, "rf") == 0)) {
                    snprintf(pending_mode, sizeof(pending_mode), "%s", requested);
                    mode_request = parse_request(space + 1);
                    mode_pending = true;
                }
            }
        }
        return true;
    }
    const char *target = NULL;
    if (strncmp(line, "apps sentinel", 13) == 0
        && (line[13] == '\0' || line[13] == ' ')) {
        target = "sentinel";
        value = line + 13;
    } else if (strncmp(line, "apps controller", 15) == 0
               && (line[15] == '\0' || line[15] == ' ')) {
        target = "controller";
        value = line + 15;
    } else {
        return false;
    }
    request = parse_request(value);
    if (strcmp(running_app, "chooser") != 0) {
        printf("@APP {\"type\":\"error\",\"code\":%d,\"request\":%" PRIu32 "}\n",
               ESP_ERR_INVALID_STATE, request);
        fflush(stdout);
        return true;
    }
    const esp_err_t result = app_slots_switch(target, request);
    if (result != ESP_OK) {
        printf("@APP {\"type\":\"error\",\"code\":%d,\"request\":%" PRIu32 "}\n",
               result, request);
        fflush(stdout);
    }
    return true;
}
