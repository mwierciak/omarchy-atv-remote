#!/usr/bin/env python3
"""Parse Apple TV services from Avahi's machine-readable output."""

import asyncio
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from safe_io import read_file, atomic_write, directory
from bounded_process import capture


def cache_path():
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy/apple-tv-remote/devices.json"


def load_known_devices():
    try:
        records = json.loads(read_file(cache_path(), 16384))
        if not isinstance(records, dict) or len(records) > 32:
            return {}
        return {identifier: str(ipaddress.IPv4Address(address))
                for identifier, address in records.items()
                if isinstance(identifier, str) and len(identifier) <= 128}
    except (OSError, ValueError, TypeError, ipaddress.AddressValueError):
        return {}


def remember_devices(devices):
    records = load_known_devices()
    records.update({device["identifier"]: device["address"] for device in devices})
    if len(records) > 32:
        records = {device["identifier"]: device["address"] for device in devices}
    try:
        path = cache_path()
        os.close(directory(path.parent))
        atomic_write(path, json.dumps(records))
    except OSError:
        # A cache failure must not hide successfully discovered TVs.
        pass


def validate_devices(devices):
    if len(devices) > 32:
        raise ValueError("Too many Apple TVs in discovery results")
    for device in devices:
        for key in ("name", "identifier", "deviceIdentifier", "model"):
            value = device.get(key)
            if not isinstance(value, str) or len(value) > 128:
                raise ValueError("Invalid or oversized device metadata")
        device["address"] = str(ipaddress.IPv4Address(device["address"]))
    return devices


async def discover_known_devices(known):
    if not known:
        return []
    import pyatv
    from pyatv.const import Protocol

    devices = await pyatv.scan(asyncio.get_running_loop(),
                               hosts=list(dict.fromkeys(known.values())), timeout=3)
    result = []
    for device in devices:
        service = device.get_service(Protocol.AirPlay)
        identifier = service.identifier.upper() if service and service.identifier else ""
        # IP addresses can be reassigned. Only accept a previously seen TV's ID.
        if identifier not in known:
            continue
        result.append({"name": device.name, "identifier": identifier,
                       "deviceIdentifier": identifier, "address": str(device.address),
                       "model": str(device.device_info)})
    return validate_devices(result)



def local_candidates():
    """Bound discovery to directly connected private IPv4 LANs."""
    try:
        routes = json.loads(capture(["/usr/bin/ip", "-j", "route", "show", "scope", "link"], timeout=2, limit=16384).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    candidates = []
    for route in routes:
        try:
            interface = route.get("dev", "")
            network = ipaddress.IPv4Network(route.get("dst", ""))
            # Active scanning is deliberately limited to conventional physical
            # Ethernet and Wi-Fi interfaces. VPN and virtual interface names
            # vary too widely for a safe denylist.
            if not isinstance(interface, str) or not interface.startswith(("en", "eth", "wl")):
                continue
            private_lans = (ipaddress.IPv4Network("10.0.0.0/8"),
                            ipaddress.IPv4Network("172.16.0.0/12"),
                            ipaddress.IPv4Network("192.168.0.0/16"))
            if not any(network.subnet_of(block) for block in private_lans):
                continue
            # Avoid sweeping a large enterprise/VPN network.
            if network.prefixlen < 24:
                network = ipaddress.IPv4Network(str(route["prefsrc"]) + "/24", strict=False)
            candidates.extend(str(host) for host in network.hosts() if str(host) != route.get("prefsrc"))
        except (KeyError, ValueError):
            continue
    return list(dict.fromkeys(candidates))[:508]


async def rediscover_network():
    """Find AirPlay listeners, then identify Apple TVs without sending controls."""
    import pyatv
    from pyatv.const import Protocol, OperatingSystem
    semaphore = asyncio.Semaphore(32)

    async def probe(address):
        async with semaphore:
            try:
                _, writer = await asyncio.wait_for(asyncio.open_connection(address, 7000), .6)
                writer.close()
                await writer.wait_closed()
                return address
            except (OSError, asyncio.TimeoutError):
                return None

    hosts = [host for host in await asyncio.gather(*(probe(host) for host in local_candidates())) if host]
    if not hosts:
        return []
    devices = await pyatv.scan(asyncio.get_running_loop(), hosts=hosts, timeout=3)
    result = []
    for device in devices:
        service = device.get_service(Protocol.AirPlay)
        if device.device_info.operating_system != OperatingSystem.TvOS or not service or not service.identifier:
            continue
        identifier = service.identifier.upper()
        result.append({"name": device.name, "identifier": identifier,
                       "deviceIdentifier": identifier, "address": str(device.address),
                       "model": str(device.device_info)})
    return validate_devices(result)

def decode_avahi(value):
    raw = bytearray()
    index = 0
    while index < len(value):
        match = re.match(r"\\(\d{3})", value[index:])
        if match:
            raw.append(int(match.group(1)))
            index += 4
        else:
            raw.extend(value[index].encode())
            index += 1
    return raw.decode("utf-8", errors="replace")


def parse_services(output):
    result = []
    seen = set()
    if len(output) > 65536:
        raise ValueError("Discovery output exceeds its size limit")
    for line in output.splitlines():
        fields = line.split(";", 9)
        if len(fields) < 10 or fields[0] != "=" or fields[2] != "IPv4":
            continue
        name, address, txt = fields[3], fields[7], fields[9]
        model = re.search(r'"model=([^" ]+)', txt)
        device_id = re.search(r'"deviceid=([^" ]+)', txt, re.IGNORECASE)
        if not model or not model.group(1).startswith("AppleTV") or not device_id:
            continue
        stable_id = device_id.group(1).upper()
        if stable_id in seen:
            continue
        seen.add(stable_id)
        result.append({"name": decode_avahi(name), "identifier": stable_id,
                       "deviceIdentifier": stable_id, "address": address,
                       "model": model.group(1)})
    return validate_devices(result)


def main(scan_network=False):
    devices = []
    error = ""
    try:
        scan = capture(["/usr/bin/avahi-browse", "-rtp", "_airplay._tcp"], timeout=8)
        devices = parse_services(scan.stdout)
        if scan.returncode != 0 and not devices:
            error = "Apple TV discovery failed"
    except FileNotFoundError:
        error = "avahi-browse is not installed"
    except subprocess.TimeoutExpired:
        error = "Apple TV discovery timed out"
    except (ValueError, OSError):
        error = "Invalid Apple TV discovery data"
    found = {device["identifier"] for device in devices}
    missing = {identifier: address for identifier, address in load_known_devices().items()
               if identifier not in found}
    try:
        devices.extend(asyncio.run(discover_known_devices(missing)))
    except Exception as failure:
        if not devices:
            error = "Could not discover saved Apple TVs"
    # Recover a moved TV, and support first discovery on multicast-blocked LANs.
    if scan_network or not devices or any(identifier not in {d["identifier"] for d in devices} for identifier in missing):
        try:
            recovered = asyncio.run(rediscover_network())
            found = {d["identifier"] for d in devices}
            devices.extend(d for d in recovered if d["identifier"] not in found)
        except Exception as failure:
            if not devices:
                error = "Network discovery failed"
    devices = validate_devices(devices)
    if devices:
        error = ""
        remember_devices(devices)
    print(json.dumps({"error": error, "devices": devices}))
    return 0 if not error else 1


if __name__ == "__main__":
    sys.exit(main(scan_network="--network" in sys.argv[1:]))
