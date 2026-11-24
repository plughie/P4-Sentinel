# Architecture

The P4 bootloader selects one application image at a time. The factory app is
the chooser. Network Scanner and RF Monitor occupy separate OTA slots; the
optional Synesthesia controller uses a third OTA slot. The chooser and running
apps exchange newline-delimited JSON status events over USB Serial/JTAG.

A switch writes the target app and request ID to NVS, selects the target
partition, reports a switching event, and restarts. On startup the selected app
reports its scene and consumes the matching request ID. `apps back <id>` requests
cleanup, returns to the factory partition, and restarts. Network discovery is
canceled before leaving Network Scanner. The RF tuner and SD log handles are
stopped/flushed before leaving RF Monitor.

The partition layout reserves:

- NVS at `0x9000` (`0x6000` bytes)
- OTA metadata at `0xF000` (`0x2000` bytes)
- PHY data at `0x11000` (`0x1000` bytes)
- chooser at `0x20000` (`0x100000` bytes)
- Network Scanner at `0x120000` (`0x200000` bytes)
- RF Monitor at `0x320000` (`0x400000` bytes)
- Synesthesia controller at `0x720000` (`0x400000` bytes)
- installed-app manifest at `0xB20000` (`0x1000` bytes)

The installer writes the manifest with a `P4S1` header and installed-app bits.
The chooser checks those bits before selecting a slot, preventing an older
image left in an omitted slot from appearing installed.

Switching between apps requires a reboot. Apps are not multitasked. This
partition layout requires a coordinated bootloader/partition-table migration;
only the installation framework should prepare the multi-image write plan.
