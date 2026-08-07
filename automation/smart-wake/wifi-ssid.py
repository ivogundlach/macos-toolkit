#!/usr/bin/python3
import plistlib
import re
import subprocess
import sys
from plistlib import UID


def resolve(value, objects):
    if isinstance(value, UID):
        return resolve(objects[value.data], objects)
    if isinstance(value, dict):
        if "NS.keys" in value and "NS.objects" in value:
            keys = resolve(value["NS.keys"], objects)
            vals = resolve(value["NS.objects"], objects)
            return {k: v for k, v in zip(keys, vals)}
        if "NS.objects" in value:
            return resolve(value["NS.objects"], objects)
        return {k: resolve(v, objects) for k, v in value.items() if k != "$class"}
    if isinstance(value, list):
        return [resolve(v, objects) for v in value]
    return value


def ssid_from_airport_state(interface="en0"):
    try:
        output = subprocess.check_output(
            ["scutil"],
            input=f"show State:/Network/Interface/{interface}/AirPort\n".encode(),
            stderr=subprocess.DEVNULL,
        ).decode("utf-8", "ignore")
    except Exception:
        return None

    match = re.search(r"CachedScanRecord : <data> 0x([0-9a-fA-F]+)", output)
    if not match:
        return None

    try:
        archive = plistlib.loads(bytes.fromhex(match.group(1)))
        root = resolve(archive["$top"]["root"], archive["$objects"])
    except Exception:
        return None

    ssid = root.get("SSID_STR")
    if isinstance(ssid, str) and ssid:
        return ssid

    raw_ssid = root.get("SSID")
    if isinstance(raw_ssid, bytes):
        try:
            return raw_ssid.decode("utf-8")
        except UnicodeDecodeError:
            return None

    return None


def ssid_from_system_profiler():
    try:
        output = subprocess.check_output(
            ["system_profiler", "SPAirPortDataType"],
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).decode("utf-8", "ignore")
    except Exception:
        return None

    in_current_network = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "Current Network Information:":
            in_current_network = True
            continue
        if in_current_network:
            match = re.match(r"([^:]+):$", stripped)
            if match:
                ssid = match.group(1).strip()
                if ssid and ssid != "Network Type":
                    return ssid
            if stripped.startswith("Other Local Wi-Fi Networks:"):
                return None

    return None


def main():
    ssid = ssid_from_airport_state() or ssid_from_system_profiler()
    if not ssid:
        return 1
    print(ssid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
