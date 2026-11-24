# P4 Sentinel application slots

The ESP32-P4 boots a small factory chooser, then one of two independent application images. RF Sentinel combines the Wi-Fi/Bluetooth LE Network Scanner and RTL-SDR RF Monitor in a single 6 MiB slot. The 4 MiB second slot is reserved for the Synesthesia controller; it remains blank and unavailable until a compatible controller image is supplied.

| Partition | Offset | Size | Purpose |
| --- | ---: | ---: | --- |
| factory | `0x020000` | 1 MiB | USB app chooser |
| `ota_0` | `0x120000` | 6 MiB | RF Sentinel |
| `ota_1` | `0x720000` | 4 MiB | Reserved Synesthesia controller |
| app_manifest | `0xB20000` | 4 KiB | Installed-system flags and first Sentinel view |

This targets 16 MiB flash. The remaining region is unassigned and is not
formatted as a filesystem. External SD storage is unaffected.

## Switching behavior

The chooser launches RF Sentinel or an installed controller. Inside RF Sentinel,
the Mac view offers Network Scanner and RF Monitor. Only one view runs at a
time; changing between them cleans up the current receiver and reboots into the
same RF Sentinel slot. Returning to the system chooser also reboots. A future
controller image must implement `apps back <request-id>` to return.

## Installer safety

`tools/p4_install.py` creates an address-based flash plan, never a padded raw
image. It writes the bootloader, partition table, OTA metadata, chooser, selected
app images, and installed-app manifest at fixed, checked addresses. It leaves
NVS (`0x9000–0xEFFF`), the SD card, and omitted application partitions alone.
Flashing requires an explicit `--yes`, a 16 MiB chip check, and a fresh verified
full-flash backup.

Profiles:

- `sentinel`: chooser plus the combined RF Sentinel image; controller slot stays reserved.
- `network` / `rf`: same Sentinel image, starting in the selected view.
- `controller`: requires an externally built controller image.
- `combined`: Sentinel plus the externally built controller image.

The installed-app manifest prevents stale controller contents from being
selectable when no controller image was included.
