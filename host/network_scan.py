#!/usr/bin/env python3
"""Display network scan records from a USB serial port or a saved log."""

import argparse
from functools import partial
import json
import queue
import sys
import threading
import time


def display(lines):
    for line in lines:
        try:
            event = json.loads(line)
            if not isinstance(event, dict):
                continue
            match event.get("type"):
                case "wifi_ap":
                    ssid = bytes.fromhex(event["ssid_hex"]).decode("utf-8", "replace")
                    print(
                        f"Wi-Fi  ch {event['channel']:>2}  {event['rssi']:>4} dBm  "
                        f"{event['bssid']}  {ssid or '<hidden>'!r}",
                        flush=True,
                    )
                case "ble_advertisement":
                    name = bytes.fromhex(event.get("name_hex", "")).decode("utf-8", "replace")
                    name_text = f"  {name!r}" if name else ""
                    print(
                        f"BLE           {event['rssi']:>4} dBm  {event['address']}  "
                        f"(address type {event['address_type']}){name_text}",
                        flush=True,
                    )
                case "ble_target_check":
                    state = "seen" if event["seen"] else "not seen"
                    rssi = f", {event['rssi']} dBm" if event["seen"] else ""
                    print(
                        f"BLE target {event['name']}: {state} at {event['address']} "
                        f"(MAC match: {event['address_seen']}, name match: {event['name_seen']}){rssi}",
                        flush=True,
                    )
                case "scan_complete":
                    count = f" ({event['count']} networks)" if "count" in event else ""
                    print(f"{event['radio']} scan complete{count}", flush=True)
                case "scan_error":
                    print(f"{event['radio']} scan failed ({event['code']})", flush=True)
        except (KeyError, TypeError, ValueError, UnicodeError):
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="USB serial device. Omit to read a log from stdin.")
    parser.add_argument("--json", action="store_true", help="Pass valid JSON records through unchanged.")
    parser.add_argument("--restart", action="store_true", help="Restart the board to run its boot scans.")
    parser.add_argument("--commands", action="store_true", help="Forward commands on stdin to the board.")
    parser.add_argument("--prefix", default="", help="Only read JSON records with this prefix.")
    parser.add_argument("--app-events", action="store_true", help="Read tagged app chooser and RF records.")
    args = parser.parse_args()
    if (args.restart or args.commands) and args.port is None:
        parser.error("--restart and --commands require --port")
    if (args.prefix or args.app_events) and not args.json:
        parser.error("--prefix and --app-events require --json")
    output = partial(stream_json, prefix=args.prefix.encode(), app_events=args.app_events) if args.json else display
    if args.port is None:
        output(sys.stdin)
        return

    import serial

    link = SerialLink()
    if args.commands:
        threading.Thread(target=forward_commands, args=(link,), daemon=True).start()
        threading.Thread(target=write_commands, args=(link,), daemon=True).start()
    first_open = True
    while not link.stop.is_set():
        device = None
        try:
            device = serial.Serial(args.port, baudrate=115200, exclusive=True,
                                  write_timeout=2, timeout=None)
            device.dtr = device.rts = False
            link.attach(device)
            if first_open and args.restart:
                device.rts = True
                time.sleep(0.2)
                device.rts = False
            first_open = False
            output(iter(device.readline, b""))
        except (serial.SerialException, OSError):
            # Slot changes restart the P4 and briefly remove its USB serial device.
            pass
        finally:
            if device is not None:
                link.detach(device)
                try:
                    device.close()
                except OSError:
                    pass
        time.sleep(0.25)


class SerialLink:
    def __init__(self):
        self.device = None
        self.lock = threading.Lock()
        self.commands = queue.Queue()
        self.stop = threading.Event()

    def attach(self, device):
        with self.lock:
            self.device = device

    def detach(self, device):
        with self.lock:
            if self.device is device:
                self.device = None


def forward_commands(link):
    try:
        for line in sys.stdin.buffer:
            link.commands.put(line)
    except OSError as error:
        print(f"Serial command failed: {error}", file=sys.stderr, flush=True)
    finally:
        link.commands.put(None)


def write_commands(link):
    import serial

    while True:
        command = link.commands.get()
        if command is None:
            link.stop.set()
            with link.lock:
                device = link.device
            if device is not None:
                try:
                    device.cancel_read()
                except OSError:
                    pass
            return
        while True:
            with link.lock:
                device = link.device
            if device is None:
                time.sleep(0.1)
                continue
            try:
                device.write(command)
                break
            except (OSError, serial.SerialException):
                time.sleep(0.1)


def stream_json(lines, prefix=b"", app_events=False):
    audio_lines = audio_bytes = audio_errors = 0
    audio_error_detail = ""
    last_audio_report = time.monotonic()

    def report_audio_bridge(source):
        event = {
            "type": "audio_bridge_metrics",
            "audio_lines": audio_lines,
            "audio_bytes": audio_bytes,
            "audio_errors": audio_errors,
            "audio_error_detail": audio_error_detail,
        }
        if source:
            event["source"] = source
        print(json.dumps(event), flush=True)

    for line in lines:
        raw = line.encode() if isinstance(line, str) else line
        if prefix and not raw.startswith(prefix):
            continue
        raw = raw[len(prefix):]
        audio_hint = b'"type":"audio_pcm"' in raw
        source = None
        if app_events:
            if raw.startswith(b"@APP "):
                source, raw = "chooser", raw[5:]
            elif raw.startswith(b"@RF "):
                source, raw = "rf", raw[4:]
            else:
                source = "network"
        try:
            event = json.loads(raw)
        except (ValueError, UnicodeError) as error:
            if audio_hint:
                audio_errors += 1
                if isinstance(error, json.JSONDecodeError):
                    audio_error_detail = f"{error.msg} at char {error.pos}/{len(raw)}"
                else:
                    audio_error_detail = f"{type(error).__name__} at line length {len(raw)}"
            if time.monotonic() - last_audio_report >= 1:
                report_audio_bridge(source)
                last_audio_report = time.monotonic()
            continue
        if isinstance(event, dict):
            if event.get("type") == "audio_started":
                audio_lines = audio_bytes = audio_errors = 0
                audio_error_detail = ""
            if event.get("type") == "audio_pcm":
                audio_lines += 1
                audio_bytes += len(raw)
            if source:
                event["source"] = source
            print(json.dumps(event), flush=True)
            if time.monotonic() - last_audio_report >= 1:
                report_audio_bridge(source)
                last_audio_report = time.monotonic()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
