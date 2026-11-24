#include "rf_storage.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/statvfs.h>

#include "driver/gpio.h"
#include "driver/sdmmc_host.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdmmc_cmd.h"
#include "sd_pwr_ctrl_by_on_chip_ldo.h"

enum {
    SD_POWER_GPIO = 45,
    SD_LDO_CHANNEL = 4,
    SD_CLK_GPIO = 43,
    SD_CMD_GPIO = 44,
    SD_D0_GPIO = 39,
    SD_D1_GPIO = 40,
    SD_D2_GPIO = 41,
    SD_D3_GPIO = 42,
};

#define SD_MOUNT_POINT "/sdcard"
#define RF_DATA_DIR SD_MOUNT_POINT "/RF_SENTINEL"
#define RF_EVENTS_PATH RF_DATA_DIR "/events.jsonl"
#define RF_SYSTEM_LOG_PATH RF_DATA_DIR "/system.log"
#define FAA_MASTER_PATH SD_MOUNT_POINT "/FAA Catalog/MASTER.txt"

static sdmmc_card_t *card;
static sd_pwr_ctrl_handle_t power_control;
static FILE *events_file;
static FILE *system_log;
static SemaphoreHandle_t storage_mutex;
static bool mounted;
static bool logging_enabled = true;
static uint64_t capacity_bytes;
static char last_error[96] = "";

static void remember_error(const char *operation, esp_err_t error)
{
    snprintf(last_error, sizeof(last_error), "%s: %s", operation, esp_err_to_name(error));
}

static void write_system_log_locked(const char *message)
{
    if (!system_log || !message) return;
    fprintf(system_log, "%" PRIu64 " %s\n", (uint64_t)(esp_timer_get_time() / 1000), message);
    fflush(system_log);
}

esp_err_t rf_storage_init(void)
{
    if (!storage_mutex) {
        storage_mutex = xSemaphoreCreateMutex();
        if (!storage_mutex) return ESP_ERR_NO_MEM;
    }
    if (mounted) {
        events_file = fopen(RF_EVENTS_PATH, "a");
        system_log = fopen(RF_SYSTEM_LOG_PATH, "a");
        if (!events_file || !system_log) {
            if (events_file) fclose(events_file);
            if (system_log) fclose(system_log);
            events_file = system_log = NULL;
            snprintf(last_error, sizeof(last_error), "Reopen RF_SENTINEL log files failed");
            return ESP_FAIL;
        }
        xSemaphoreTake(storage_mutex, portMAX_DELAY);
        write_system_log_locked("RF Monitor session opened; JSONL logging enabled");
        xSemaphoreGive(storage_mutex);
        last_error[0] = '\0';
        return ESP_OK;
    }

    // The SDMMC signal bank, including GPIO45, is powered from on-chip LDO
    // channel 4. Configure the active-low TF-card VDD switch only after that
    // bank is enabled.
    sd_pwr_ctrl_ldo_config_t ldo_config = {.ldo_chan_id = SD_LDO_CHANNEL};
    esp_err_t result = sd_pwr_ctrl_new_on_chip_ldo(&ldo_config, &power_control);
    if (result != ESP_OK) {
        remember_error("SD signal power", result);
        return result;
    }

    gpio_config_t power_pin = {
        .pin_bit_mask = 1ULL << SD_POWER_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    result = gpio_config(&power_pin);
    if (result != ESP_OK) {
        remember_error("SD power pin", result);
        (void)sd_pwr_ctrl_del_on_chip_ldo(power_control);
        power_control = NULL;
        return result;
    }
    result = gpio_set_level(SD_POWER_GPIO, 0);
    if (result != ESP_OK) {
        remember_error("SD power enable", result);
        (void)sd_pwr_ctrl_del_on_chip_ldo(power_control);
        power_control = NULL;
        return result;
    }
    vTaskDelay(pdMS_TO_TICKS(20));

    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_DEFAULT;
    host.pwr_ctrl_handle = power_control;

    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 4;
    slot.clk = SD_CLK_GPIO;
    slot.cmd = SD_CMD_GPIO;
    slot.d0 = SD_D0_GPIO;
    slot.d1 = SD_D1_GPIO;
    slot.d2 = SD_D2_GPIO;
    slot.d3 = SD_D3_GPIO;
    slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;

    const esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 8,
        .allocation_unit_size = 16 * 1024,
    };
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
        result = esp_vfs_fat_sdmmc_mount(SD_MOUNT_POINT, &host, &slot,
                                         &mount_config, &card);
        if (result == ESP_OK || result != ESP_ERR_INVALID_STATE || attempt == 1) break;
        // ESP-IDF can briefly report the P4 host slot as busy during first use.
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (result != ESP_OK) {
        remember_error("SD mount (card left unformatted)", result);
        (void)sd_pwr_ctrl_del_on_chip_ldo(power_control);
        power_control = NULL;
        (void)gpio_set_level(SD_POWER_GPIO, 1);
        return result;
    }

    struct statvfs info = {0};
    if (statvfs(SD_MOUNT_POINT, &info) == 0) {
        capacity_bytes = (uint64_t)info.f_blocks * info.f_frsize;
    } else {
        capacity_bytes = (uint64_t)card->csd.capacity * 512ULL;
    }
    if (mkdir(RF_DATA_DIR, 0775) != 0) {
        struct stat directory_info;
        if (stat(RF_DATA_DIR, &directory_info) != 0 || !S_ISDIR(directory_info.st_mode)) {
            snprintf(last_error, sizeof(last_error), "Create RF_SENTINEL directory failed");
            (void)esp_vfs_fat_sdcard_unmount(SD_MOUNT_POINT, card);
            card = NULL;
            (void)sd_pwr_ctrl_del_on_chip_ldo(power_control);
            power_control = NULL;
            (void)gpio_set_level(SD_POWER_GPIO, 1);
            return ESP_FAIL;
        }
    }

    events_file = fopen(RF_EVENTS_PATH, "a");
    system_log = fopen(RF_SYSTEM_LOG_PATH, "a");
    if (!events_file || !system_log) {
        snprintf(last_error, sizeof(last_error), "Open RF_SENTINEL log files failed");
        if (events_file) fclose(events_file);
        if (system_log) fclose(system_log);
        events_file = system_log = NULL;
        (void)esp_vfs_fat_sdcard_unmount(SD_MOUNT_POINT, card);
        card = NULL;
        (void)sd_pwr_ctrl_del_on_chip_ldo(power_control);
        power_control = NULL;
        (void)gpio_set_level(SD_POWER_GPIO, 1);
        return ESP_FAIL;
    }

    mounted = true;
    last_error[0] = '\0';
    xSemaphoreTake(storage_mutex, portMAX_DELAY);
    write_system_log_locked("RF Monitor session opened; JSONL logging enabled");
    xSemaphoreGive(storage_mutex);
    return ESP_OK;
}

void rf_storage_end_session(void)
{
    if (!storage_mutex) return;
    xSemaphoreTake(storage_mutex, portMAX_DELAY);
    if (system_log) write_system_log_locked("RF Monitor session closed");
    if (events_file) { fflush(events_file); fclose(events_file); events_file = NULL; }
    if (system_log) { fflush(system_log); fclose(system_log); system_log = NULL; }
    xSemaphoreGive(storage_mutex);
}

static bool should_persist_event(const char *line)
{
    static const char *const ignored_types[] = {
        "iq_waveform", "iq_metrics", "adsb_metrics", "tetra_metrics",
        "p25_metrics", "pager_metrics", "tpms_metrics", "find_metrics",
        "audio_metrics", "audio_pcm", "audio_bridge_metrics", "sd_status",
    };
    const char *type = strstr(line, "\"type\":\"");
    if (!type) return false;
    type += sizeof("\"type\":\"") - 1;
    for (size_t index = 0; index < sizeof(ignored_types) / sizeof(ignored_types[0]); ++index) {
        const size_t length = strlen(ignored_types[index]);
        if (strncmp(type, ignored_types[index], length) == 0 && type[length] == '"') return false;
    }
    return true;
}

void rf_storage_record_event(const char *line, size_t length)
{
    if (!line || !length || !mounted || !logging_enabled || !should_persist_event(line)) return;
    const char *json = strncmp(line, "@RF ", 4) == 0 ? line + 4 : line;
    size_t json_length = length - (size_t)(json - line);
    while (json_length && (json[json_length - 1] == '\n' || json[json_length - 1] == '\r')) --json_length;
    if (!json_length || json[0] != '{') return;

    xSemaphoreTake(storage_mutex, portMAX_DELAY);
    if (events_file) {
        fprintf(events_file, "{\"uptime_ms\":%" PRIu64 ",\"event\":", (uint64_t)(esp_timer_get_time() / 1000));
        fwrite(json, 1, json_length, events_file);
        fputs("}\n", events_file);
        if (fflush(events_file) != 0) snprintf(last_error, sizeof(last_error), "Write events.jsonl failed");
    }
    xSemaphoreGive(storage_mutex);
}

void rf_storage_set_logging(bool enabled)
{
    if (!storage_mutex) return;
    xSemaphoreTake(storage_mutex, portMAX_DELAY);
    logging_enabled = enabled;
    write_system_log_locked(enabled ? "JSONL event logging enabled" : "JSONL event logging disabled");
    xSemaphoreGive(storage_mutex);
}

bool rf_storage_is_mounted(void) { return mounted; }
bool rf_storage_is_logging(void) { return logging_enabled; }
uint64_t rf_storage_capacity_bytes(void) { return capacity_bytes; }

uint64_t rf_storage_free_bytes(void)
{
    uint64_t total = 0, free = 0;
    if (!mounted || esp_vfs_fat_info(SD_MOUNT_POINT, &total, &free) != ESP_OK) return 0;
    return free;
}

bool rf_storage_faa_master_present(void)
{
    return mounted && access(FAA_MASTER_PATH, F_OK) == 0;
}

typedef struct {
    char address[7];
    bool found;
} faa_target_t;

static size_t parse_csv_fields(char *line, char **fields, size_t field_capacity)
{
    char *read = line, *write = line;
    size_t count = 0;
    bool quoted = false;
    if (field_capacity == 0) return 0;
    fields[count++] = write;
    while (*read) {
        if (*read == '"') {
            if (quoted && read[1] == '"') {
                *write++ = '"';
                read += 2;
            } else {
                quoted = !quoted;
                ++read;
            }
        } else if (*read == ',' && !quoted) {
            *write++ = '\0';
            ++read;
            if (count == field_capacity) return 0;
            fields[count++] = write;
        } else if ((*read == '\r' || *read == '\n') && !quoted) {
            ++read;
            break;
        } else {
            *write++ = *read++;
        }
    }
    *write = '\0';
    return quoted ? 0 : count;
}

static void copy_trimmed_field(const char *source, char *destination, size_t size)
{
    if (!size) return;
    while (source && (*source == ' ' || *source == '\t')) ++source;
    size_t length = source ? strlen(source) : 0;
    while (length && (source[length - 1] == ' ' || source[length - 1] == '\t'
                      || source[length - 1] == '\r' || source[length - 1] == '\n')) --length;
    if (length >= size) length = size - 1;
    if (length) memcpy(destination, source, length);
    destination[length] = '\0';
}

static bool normalize_mode_s(const char *source, char address[7])
{
    size_t length = 0;
    while (source && *source && length < 6) {
        const unsigned char value = (unsigned char)*source++;
        if (value == ' ' || value == '\t' || value == '\r' || value == '\n') continue;
        if (!((value >= '0' && value <= '9') || (value >= 'A' && value <= 'F')
              || (value >= 'a' && value <= 'f'))) return false;
        address[length++] = (char)((value >= 'a' && value <= 'f') ? value - 32 : value);
    }
    if (length != 6) return false;
    address[6] = '\0';
    return true;
}

esp_err_t rf_storage_match_faa_master(const char *addresses,
                                      rf_storage_faa_match_callback_t callback,
                                      uint32_t *matches)
{
    if (matches) *matches = 0;
    if (!mounted || !addresses || !callback) {
        snprintf(last_error, sizeof(last_error), "SD card or FAA lookup unavailable");
        return ESP_ERR_INVALID_STATE;
    }
    faa_target_t targets[64] = {0};
    size_t target_count = 0;
    const char *cursor = addresses;
    while (*cursor) {
        while (*cursor == ',' || *cursor == ' ' || *cursor == '\t') ++cursor;
        if (!*cursor) break;
        char address[7] = {0};
        size_t length = 0;
        while (*cursor && *cursor != ',' && length < 6) {
            const unsigned char value = (unsigned char)*cursor++;
            if (!((value >= '0' && value <= '9') || (value >= 'A' && value <= 'F')
                  || (value >= 'a' && value <= 'f'))) {
                snprintf(last_error, sizeof(last_error), "Invalid ICAO address in FAA lookup");
                return ESP_ERR_INVALID_ARG;
            }
            address[length++] = (char)((value >= 'a' && value <= 'f') ? value - 32 : value);
        }
        if (length != 6 || (*cursor && *cursor != ',')) {
            snprintf(last_error, sizeof(last_error), "FAA lookup accepts up to 64 six-digit ICAO addresses");
            return ESP_ERR_INVALID_ARG;
        }
        if (*cursor == ',') ++cursor;
        else if (*cursor != '\0') {
            snprintf(last_error, sizeof(last_error), "Invalid FAA lookup address list");
            return ESP_ERR_INVALID_ARG;
        }
        bool duplicate = false;
        for (size_t i = 0; i < target_count; ++i)
            if (strcmp(targets[i].address, address) == 0) duplicate = true;
        if (!duplicate) {
            if (target_count == sizeof(targets) / sizeof(targets[0])) {
                snprintf(last_error, sizeof(last_error), "FAA lookup accepts up to 64 addresses");
                return ESP_ERR_INVALID_ARG;
            }
            memcpy(targets[target_count++].address, address, sizeof(address));
        }
    }
    if (!target_count) {
        snprintf(last_error, sizeof(last_error), "No observed aircraft addresses to match");
        return ESP_ERR_INVALID_ARG;
    }

    if (storage_mutex) {
        xSemaphoreTake(storage_mutex, portMAX_DELAY);
        if (events_file) fflush(events_file);
        xSemaphoreGive(storage_mutex);
    }
    FILE *file = fopen(FAA_MASTER_PATH, "r");
    if (!file) {
        snprintf(last_error, sizeof(last_error), "Open FAA Catalog/MASTER.txt failed");
        return ESP_FAIL;
    }

    char line[1024], *fields[40];
    if (!fgets(line, sizeof(line), file)) {
        fclose(file);
        snprintf(last_error, sizeof(last_error), "FAA MASTER is empty or unreadable");
        return ESP_FAIL;
    }
    if ((unsigned char)line[0] == 0xEF && (unsigned char)line[1] == 0xBB
        && (unsigned char)line[2] == 0xBF) memmove(line, line + 3, strlen(line + 3) + 1);
    const size_t header_count = parse_csv_fields(line, fields, 40);
    size_t registration_column = SIZE_MAX, year_column = SIZE_MAX, type_column = SIZE_MAX;
    size_t date_column = SIZE_MAX, address_column = SIZE_MAX;
    for (size_t i = 0; i < header_count; ++i) {
        char value[32];
        copy_trimmed_field(fields[i], value, sizeof(value));
        if (strcmp(value, "N-NUMBER") == 0) registration_column = i;
        else if (strcmp(value, "YEAR MFR") == 0) year_column = i;
        else if (strcmp(value, "TYPE AIRCRAFT") == 0) type_column = i;
        else if (strcmp(value, "LAST ACTION DATE") == 0) date_column = i;
        else if (strcmp(value, "MODE S CODE HEX") == 0) address_column = i;
    }
    if (registration_column == SIZE_MAX || year_column == SIZE_MAX || type_column == SIZE_MAX
        || date_column == SIZE_MAX || address_column == SIZE_MAX) {
        fclose(file);
        snprintf(last_error, sizeof(last_error), "FAA MASTER columns not recognized");
        return ESP_FAIL;
    }

    uint32_t count = 0;
    while (fgets(line, sizeof(line), file)) {
        const size_t field_count = parse_csv_fields(line, fields, 40);
        if (field_count <= address_column) continue;
        char address[7];
        if (!normalize_mode_s(fields[address_column], address)) continue;
        size_t target_index = 0;
        while (target_index < target_count
               && strcmp(targets[target_index].address, address) != 0) ++target_index;
        if (target_index == target_count || targets[target_index].found) continue;
        char registration[16], year[8], aircraft_type[16], action_date[16];
        copy_trimmed_field(fields[registration_column], registration, sizeof(registration));
        copy_trimmed_field(fields[year_column], year, sizeof(year));
        copy_trimmed_field(fields[type_column], aircraft_type, sizeof(aircraft_type));
        copy_trimmed_field(fields[date_column], action_date, sizeof(action_date));
        if (!registration[0]) continue;
        char formatted_registration[17];
        if (registration[0] == 'N') snprintf(formatted_registration, sizeof(formatted_registration), "%s", registration);
        else snprintf(formatted_registration, sizeof(formatted_registration), "N%s", registration);
        targets[target_index].found = true;
        callback(address, formatted_registration, year, aircraft_type, action_date);
        ++count;
    }
    const bool read_error = ferror(file) != 0;
    fclose(file);
    if (read_error) {
        snprintf(last_error, sizeof(last_error), "Read FAA MASTER failed");
        return ESP_FAIL;
    }
    if (matches) *matches = count;
    last_error[0] = '\0';
    return ESP_OK;
}

static const char *json_value(const char *line, const char *key)
{
    static char pattern[40];
    snprintf(pattern, sizeof(pattern), "\"%s\":", key);
    const char *value = strstr(line, pattern);
    return value ? value + strlen(pattern) : NULL;
}

static bool json_string(const char *line, const char *key, char *out, size_t out_size)
{
    const char *value = json_value(line, key);
    if (!value || *value != '"' || out_size == 0) return false;
    ++value;
    size_t length = 0;
    while (*value && *value != '"' && length + 1 < out_size) {
        if (*value == '\\' && value[1]) ++value;
        out[length++] = *value++;
    }
    out[length] = '\0';
    return true;
}

static bool json_integer(const char *line, const char *key, long *out)
{
    const char *value = json_value(line, key);
    if (!value || (*value != '-' && (*value < '0' || *value > '9'))) return false;
    char *end = NULL;
    const long parsed = strtol(value, &end, 10);
    if (end == value) return false;
    *out = parsed;
    return true;
}

static void write_csv_text(FILE *file, const char *text)
{
    fputc('"', file);
    for (const char *cursor = text; *cursor; ++cursor) {
        if (*cursor == '"') fputc('"', file);
        fputc(*cursor, file);
    }
    fputc('"', file);
}

esp_err_t rf_storage_export_adsb_csv(uint32_t *rows, char *path, size_t path_size)
{
    if (rows) *rows = 0;
    if (!mounted || !events_file) {
        snprintf(last_error, sizeof(last_error), "SD card or event log unavailable");
        return ESP_ERR_INVALID_STATE;
    }
    if (!path || path_size == 0) return ESP_ERR_INVALID_ARG;

    xSemaphoreTake(storage_mutex, portMAX_DELAY);
    fflush(events_file);
    FILE *source = fopen(RF_EVENTS_PATH, "r");
    if (!source) {
        snprintf(last_error, sizeof(last_error), "Open RF event log for export failed");
        xSemaphoreGive(storage_mutex);
        return ESP_FAIL;
    }
    snprintf(path, path_size, RF_DATA_DIR "/adsb_capture_%" PRIu64 ".csv",
             (uint64_t)(esp_timer_get_time() / 1000));
    FILE *destination = fopen(path, "w");
    if (!destination) {
        snprintf(last_error, sizeof(last_error), "Create ADS-B CSV on SD failed");
        fclose(source);
        xSemaphoreGive(storage_mutex);
        return ESP_FAIL;
    }

    fputs("uptime_ms,icao24,df,type_code,callsign,altitude_ft,altitude_kind\n", destination);
    char line[768];
    uint32_t count = 0;
    while (fgets(line, sizeof(line), source)) {
        if (!strstr(line, "\"type\":\"adsb_frame\"")) continue;
        long uptime = 0, df = 0, type_code = 0, altitude = 0;
        char icao[8] = "", callsign[24] = "", altitude_kind[16] = "";
        if (!json_integer(line, "uptime_ms", &uptime)
            || !json_string(line, "icao", icao, sizeof(icao))) continue;
        (void)json_integer(line, "df", &df);
        (void)json_integer(line, "type_code", &type_code);
        (void)json_integer(line, "altitude_ft", &altitude);
        (void)json_string(line, "callsign", callsign, sizeof(callsign));
        (void)json_string(line, "altitude_kind", altitude_kind, sizeof(altitude_kind));
        fprintf(destination, "%ld,%s,%ld,%ld,", uptime, icao, df, type_code);
        write_csv_text(destination, callsign);
        fputc(',', destination);
        const char *altitude_value = json_value(line, "altitude_ft");
        if (altitude_value && (*altitude_value == '-' || (*altitude_value >= '0' && *altitude_value <= '9')))
            fprintf(destination, "%ld", altitude);
        fputc(',', destination);
        write_csv_text(destination, altitude_kind);
        fputc('\n', destination);
        ++count;
    }
    const bool source_error = ferror(source);
    const bool destination_error = ferror(destination) || fflush(destination) != 0;
    fclose(source);
    fclose(destination);
    if (source_error || destination_error || count == 0) {
        if (count == 0) (void)unlink(path);
        snprintf(last_error, sizeof(last_error), count == 0
                 ? "No logged ADS-B frames to export"
                 : "ADS-B CSV export failed while writing card");
        xSemaphoreGive(storage_mutex);
        return ESP_FAIL;
    }
    if (rows) *rows = count;
    last_error[0] = '\0';
    xSemaphoreGive(storage_mutex);
    return ESP_OK;
}

const char *rf_storage_last_error(void) { return last_error; }
