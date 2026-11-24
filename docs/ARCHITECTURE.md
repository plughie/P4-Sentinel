# Architecture

The P4 boots a factory app chooser. RF Sentinel occupies `ota_0` and contains
both the Network Scanner and RF Monitor code. The optional Synesthesia
controller has a separate `ota_1` partition. The apps are never multitasked.

The chooser first launches the RF Sentinel menu scene. The Mac host then selects
Network Scanner or RF Monitor. A view change cleans up active scan/capture state,
stores the requested view in NVS, selects the same RF Sentinel partition, and
restarts. A Back action cleans up the active view and returns to the factory
chooser. The controller image is selected only when present in the installed-app
manifest.

The partition layout is:

- NVS at `0x9000` (`0x6000` bytes)
- OTA metadata at `0xF000` (`0x2000` bytes)
- PHY data at `0x11000` (`0x1000` bytes)
- chooser at `0x20000` (`0x100000` bytes)
- RF Sentinel at `0x120000` (`0x600000` bytes)
- Synesthesia controller at `0x720000` (`0x400000` bytes)
- installed-app manifest at `0xB20000` (`0x1000` bytes)

The manifest uses a `P4S1` header, installed-system bits, and a default Sentinel
scene. The chooser checks installed bits before selecting either application,
so a blank reserved controller slot or an old image cannot be launched.

A slot switch reboots the device. The two top-level systems remain independent;
the controller source is maintained in its own repository. The installer writes
only explicit image ranges and preserves NVS and external SD data.
