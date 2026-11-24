# P4 Sentinel app slots

The ESP32-P4 uses a factory chooser and up to three independent app partitions.
Network Scanner and RF Monitor are built here. A Synesthesia controller image
can be supplied from its separate project when that image supports the slot
protocol described below.

| Partition | Offset | Size | App |
| --- | ---: | ---: | --- |
| factory | `0x020000` | 1 MiB | USB app chooser |
| `ota_0` | `0x120000` | 2 MiB | Network Scanner |
| `ota_1` | `0x320000` | 4 MiB | RF Monitor |
| `ota_2` | `0x720000` | 4 MiB | Optional Synesthesia controller |
| app_manifest | `0xB20000` | 4 KiB | Installed-app availability flags |

The table targets 16 MiB flash. The remaining region is unassigned. It is not
formatted as a filesystem. The external SD card is unaffected.

## Switching behavior

The chooser selects one app partition and restarts the P4. The app returns to
the chooser using `apps back <request-id>`. A controller image must include the
shared `firmware/app_slots` component (or implement the same USB serial command
and event protocol) to return to the chooser. Apps do not run concurrently.

## Installer safety

`tools/p4_install.py` creates an address-based flash plan. It does not create a
single padded raw image: writing a padded image could erase NVS. The plan writes
the bootloader, partition table, OTA metadata, chooser, selected app images, and
the installed-app manifest at fixed, checked addresses. It leaves NVS (`0x9000–0xEFFF`), the
SD card, and unselected app slots untouched. Flashing is opt-in and requires a
fresh full-flash backup plus `--yes`.

Profiles:

- `network` or `rf`: chooser plus one Sentinel app.
- `sentinel`: chooser, Network Scanner, and RF Monitor.
- `controller`: chooser plus an externally built controller image.
- `combined`: all Sentinel images plus an externally built controller image.

The installer writes the app manifest for each profile, so omitted but stale
images are not selectable. The chooser also reports a switch error if an image
is missing or invalid. Keep a verified recovery image before installing a
changed partition table.
