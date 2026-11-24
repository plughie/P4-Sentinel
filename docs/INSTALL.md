# Build, package, and install

## Requirements

- ESP-IDF 6.2 or newer configured for `esp32p4`.
- Python 3.10 or newer, `pyserial`, and ESP-IDF's `esptool` environment.
- For RF Monitor, a local checkout of `esp-rtl-sdr` and Espressif USB Host.
- For controller packages, a P4 app image built for the `ota_1` partition and
  the P4 Sentinel `apps back` / scene-event protocol.

## Package profiles

```sh
python3 tools/p4_install.py package --profile network --out dist/network
python3 tools/p4_install.py package --profile rf --out dist/rf
python3 tools/p4_install.py package --profile sentinel --out dist/sentinel
python3 tools/p4_install.py package --profile controller \
  --controller-image /path/to/controller.bin --out dist/controller
python3 tools/p4_install.py package --profile combined \
  --controller-image /path/to/controller.bin --out dist/combined
```

`sentinel` includes the chooser and one combined RF Sentinel image. The
`network` and `rf` profiles use that same image and start directly in the
selected view. `controller` and `combined` require a prebuilt controller image;
this repository does not build Synesthesia firmware. With `sentinel`, the
controller partition is reserved in the partition table but remains blank and
disabled in the chooser.

Packages contain separate binaries and a human-readable address-based flash
plan. They do not contain a padded all-flash image. Review `manifest.json`,
`flash-plan.txt`, app sizes, and SHA-256 values before installation. Internal
Network Scanner/RF Monitor view changes reboot into the same Sentinel partition.

## Flash

Close the Mac serial application and any serial monitor. Connect the intended
P4 over USB, then run:

```sh
python3 tools/p4_install.py flash dist/sentinel \
  --port /dev/cu.usbmodemXXXX --backup-dir ./backups --yes
```

The tool verifies the P4 target and 16 MiB flash, captures a full-flash backup,
checks its length and SHA-256, then writes only the ranges listed in the
package. NVS (`0x9000–0xEFFF`), unselected app partitions, and external SD storage
are left untouched. The backup stays local and is never uploaded.

Do not use `idf.py flash` from an app subproject for a multi-app migration: its
per-project flash arguments target the factory address. Do not flash any raw
image that spans the NVS range. App selection and return to the chooser reboot
the board and briefly disconnect USB.
