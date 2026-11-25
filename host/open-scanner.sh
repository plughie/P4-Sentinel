#!/bin/sh
set -eu

app_name="Network Scanner"
app_id="network-scanner"
app_source="ScannerWindow.swift"
initial_scene=""
case "${1:-}" in
    --rf)
        app_name="RF Monitor"
        app_id="rf-monitor"
        app_source="AppChooser.swift"
        initial_scene="rf"
        shift
        ;;
    --apps)
        app_name="P4 Sentinel Apps"
        app_id="app-chooser"
        app_source="AppChooser.swift"
        shift
        ;;
esac
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [--rf | --apps] /dev/cu.usbmodem…" >&2
    exit 2
fi
host_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python=${SCANNER_PYTHON:-python3}
python=$(command -v "$python")
"$python" -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10 or newer is required"; import serial'
apps_dir="$HOME/Library/Application Support/P4 Sentinel/Apps"
mkdir -p "$apps_dir"
build_dir=$(mktemp -d "$apps_dir/.build.XXXXXXXX")
trap 'rm -rf "$build_dir"' EXIT
app="$apps_dir/$app_name.app"
cat > "$build_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>NetworkScanner</string>
    <key>CFBundleIdentifier</key><string>local.p4sentinel.$app_id</string>
    <key>CFBundleName</key><string>$app_name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
"$python" -c 'import json, sys; json.dump(dict(zip(("python", "bridge", "port", "initialScene"), sys.argv[1:])), sys.stdout)' \
    "$python" "$host_dir/network_scan.py" "$1" "$initial_scene" > "$build_dir/serial-config.json"
if [ "$app_source" = "AppChooser.swift" ]; then
    swiftc -parse-as-library -D APP_CHOOSER "$host_dir/AppChooser.swift" \
        "$host_dir/ScannerWindow.swift" "$host_dir/FlockDetector.swift" \
        "$host_dir/BodyCameraDetector.swift" "$host_dir/PublicSafetyDetector.swift" \
        "$host_dir/TrackerDetector.swift" \
        "$host_dir/DroneIDDetector.swift" \
        "$host_dir/SmartGlassesDetector.swift" "$host_dir/SkimmerDetector.swift" \
        "$host_dir/VehicleCorrelationDetector.swift" \
        "$host_dir/BLEWatchlistStore.swift" "$host_dir/DeviceAnnotationStore.swift" \
        "$host_dir/SignalFreshness.swift" \
        "$host_dir/SignalStrengthHistory.swift" "$host_dir/WiFiChannelActivity.swift" \
        "$host_dir/WiFiNetworkEvidence.swift" \
        "$host_dir/RFMonitor.swift" "$host_dir/RFDetectors.swift" \
        "$host_dir/SerialLaunchConfiguration.swift" -o "$build_dir/NetworkScanner"
else
    swiftc -parse-as-library "$host_dir/$app_source" "$host_dir/FlockDetector.swift" \
        "$host_dir/BodyCameraDetector.swift" "$host_dir/PublicSafetyDetector.swift" \
        "$host_dir/TrackerDetector.swift" \
        "$host_dir/DroneIDDetector.swift" \
        "$host_dir/SmartGlassesDetector.swift" "$host_dir/SkimmerDetector.swift" \
        "$host_dir/VehicleCorrelationDetector.swift" \
        "$host_dir/BLEWatchlistStore.swift" "$host_dir/DeviceAnnotationStore.swift" \
        "$host_dir/SignalFreshness.swift" \
        "$host_dir/SignalStrengthHistory.swift" "$host_dir/WiFiChannelActivity.swift" \
        "$host_dir/WiFiNetworkEvidence.swift" \
        "$host_dir/SerialLaunchConfiguration.swift" \
        -o "$build_dir/NetworkScanner"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mv -f "$build_dir/Info.plist" "$app/Contents/Info.plist"
mv -f "$build_dir/serial-config.json" "$app/Contents/Resources/serial-config.json"
mv -f "$build_dir/NetworkScanner" "$app/Contents/MacOS/NetworkScanner"
open "$app"
