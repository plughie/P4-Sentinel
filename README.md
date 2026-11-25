# P4 Sentinel

Receive-only network and RF observation software for an ESP32-P4 development
board. It provides a USB app chooser, a Wi-Fi/Bluetooth LE Network Scanner, and
an RTL-SDR RF Monitor in one RF Sentinel application slot. A reserved second
application slot is available for the separate Synesthesia controller.

## What is included

- ESP-IDF firmware for a chooser and the combined RF Sentinel application.
- A macOS USB host application for the chooser and live Network/RF views.
- A packaging and installation tool that prepares selected app images and can
  install them separately or together on one P4.
- Receive-only detectors for supported BLE, ADS-B, P25, TPMS, paging, TETRA,
  and analog FM observations. Each detector reports only the evidence it can
  validate; candidates are not verified identities.

See [docs/P25.md](docs/P25.md) for the P25 activity decoder and the San Mateo
County to South Lake Tahoe control-channel candidate plan. P25 voice decoding
is intentionally out of scope; validated channel grants are shown as activity
evidence while the receiver stays on the control channel.

## Credits

- **P4 Sentinel:** Inspired by [RF Sentinel](https://github.com/CIS-C0/RFSentinel)
  by **CIS-C0**. Developed with **Codex (OpenAI)** as an AI development
  assistant. **Duv — a Bug-Mag.net project.** P4 Sentinel is an independent
  implementation; it does not include RF Sentinel source code.
- **Synesthesia Controller:** Developed with **Codex (OpenAI)** as an AI
  development assistant, with **Duv — a Bug-Mag.net project.** It has no
  inspiring project to credit.

## Build and package

Use ESP-IDF 6.2 or newer with an ESP32-P4 toolchain. RF Sentinel also requires
the separately licensed `esp-rtl-sdr` receiver component and the Espressif USB
Host component. Set `RTL_SDR_SOURCE` to a local receiver checkout.

```sh
python3 tools/p4_install.py package --profile sentinel --out dist/sentinel
python3 tools/p4_install.py package --profile combined \
  --controller-image /path/to/controller.bin --out dist/combined
```

For a controller-only package, choose `--profile controller`. The controller
firmware is maintained separately and is not included in this repository. The
`sentinel` profile reserves a controller partition but leaves it empty.

## Install

Review the generated `manifest.json` and `flash-plan.txt`. To install, make sure
the Mac serial app is closed and run:

```sh
python3 tools/p4_install.py flash dist/sentinel \
  --port /dev/cu.usbmodemXXXX --backup-dir ./backups --yes
```

The tool reads and checks a full 16 MiB backup before writing. It preserves NVS
by flashing separate address/image pairs, never a padded raw image. It does not
format or write the SD card. App switches reboot the P4; apps do not multitask.

See [installation](docs/INSTALL.md), [architecture](docs/ARCHITECTURE.md), and
[receive-only use](docs/RECEIVE_ONLY.md).

## License and third-party components

Copyright (C) 2026 Duv McIntyre. P4 Sentinel is licensed under
**AGPL-3.0-only**; see [LICENSE](LICENSE). This license covers the original
project files in this repository. The separately
supplied `esp-rtl-sdr` component is also AGPL-3.0-only by default; see its
[license terms](https://github.com/hardcoreerik/esp-rtl-sdr/blob/main/LICENSE)
and [licensing notes](https://github.com/hardcoreerik/esp-rtl-sdr/blob/main/LICENSING.md)
before building or redistributing RF Monitor firmware. It is not included in
this repository, and its separate notices and corresponding source must
accompany any distribution of a firmware image that includes it. Other
dependencies retain their own licenses.
