import importlib.util
import sys
import asyncio
import json
import pathlib
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, patch

MODULE_PATH = pathlib.Path(__file__).parents[1] / "bin" / "discovery.py"
sys.path.insert(0, str(MODULE_PATH.parent))
SPEC = importlib.util.spec_from_file_location("discovery", MODULE_PATH)
discovery = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(discovery)


class DiscoveryTests(unittest.TestCase):
    def test_decodes_utf8_avahi_escapes(self):
        self.assertEqual(discovery.decode_avahi(r"K\195\184kken\032TV"), "Køkken TV")

    def test_uses_stable_identifier_and_deduplicates(self):
        line = '=;eth0;IPv4;Living Room;_airplay._tcp;local;host;10.0.0.5;7000;"model=AppleTV14,1" "deviceid=aa:bb"'
        devices = discovery.parse_services(f"{line}\n{line}\n")
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0]["identifier"], "AA:BB")
        self.assertEqual(devices[0]["address"], "10.0.0.5")

    def test_ignores_non_apple_devices(self):
        line = '=;eth0;IPv4;Speaker;_airplay._tcp;local;host;10.0.0.8;7000;"model=AudioAccessory1,1" "deviceid=aa:cc"'
        self.assertEqual(discovery.parse_services(line), [])

    def test_cache_remembers_tv_after_address_change(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "devices.json"
            with patch.object(discovery, "cache_path", return_value=path):
                discovery.remember_devices([{"identifier": "AA:BB", "address": "10.0.0.5"}])
                discovery.remember_devices([{"identifier": "AA:BB", "address": "10.0.0.9"}])
                self.assertEqual(discovery.load_known_devices(), {"AA:BB": "10.0.0.9"})
                path.write_text(json.dumps({"AA:BB": "invalid"}))
                self.assertEqual(discovery.load_known_devices(), {})

    def test_direct_discovery_verifies_identity_and_never_returns_offline_cache(self):
        def device(identifier):
            return types.SimpleNamespace(name="TV", address="10.0.0.5", device_info="Apple TV",
                                         get_service=lambda _: types.SimpleNamespace(identifier=identifier))
        scan = AsyncMock()
        modules = {"pyatv": types.SimpleNamespace(scan=scan),
                   "pyatv.const": types.SimpleNamespace(Protocol=types.SimpleNamespace(AirPlay=1))}
        with patch.dict("sys.modules", modules):
            for replies, count in (([], 0), ([device("CC:DD")], 0), ([device("aa:bb")], 1)):
                scan.return_value = replies
                found = asyncio.run(discovery.discover_known_devices({"AA:BB": "10.0.0.5"}))
                self.assertEqual(len(found), count)
                self.assertEqual(scan.call_args.kwargs["hosts"], ["10.0.0.5"])
                if found:
                    self.assertEqual(found[0]["identifier"], "AA:BB")

    def test_limits_recovery_to_local_lan(self):
        routes = [{"dst": "192.168.1.0/24", "dev": "wlan0", "prefsrc": "192.168.1.5"},
                  {"dst": "100.64.0.0/10", "dev": "tailscale0"},
                  {"dst": "10.8.0.0/24", "dev": "tun0", "prefsrc": "10.8.0.2"},
                  {"dst": "10.9.0.0/24", "dev": "wg0", "prefsrc": "10.9.0.2"},
                  {"dst": "172.17.0.0/16", "dev": "docker0"},
                  {"dst": "203.0.113.0/24", "dev": "eth0", "prefsrc": "203.0.113.2"}]
        with patch.object(discovery, "capture", return_value=types.SimpleNamespace(stdout=json.dumps(routes))):
            hosts = discovery.local_candidates()
        self.assertEqual(len(hosts), 253)
        self.assertIn("192.168.1.213", hosts)
        self.assertNotIn("192.168.1.5", hosts)
        self.assertNotIn("10.8.0.3", hosts)
        self.assertNotIn("10.9.0.3", hosts)

    def test_recovers_moved_tv_and_updates_cache(self):
        moved = {"name": "TV", "identifier": "AA:BB", "deviceIdentifier": "AA:BB", "model": "AppleTV", "address": "10.0.0.9"}
        with patch.object(discovery, "capture", return_value=types.SimpleNamespace(stdout="", returncode=0)), \
             patch.object(discovery, "load_known_devices", return_value={"AA:BB": "10.0.0.5"}), \
             patch.object(discovery, "discover_known_devices", AsyncMock(return_value=[])), \
             patch.object(discovery, "rediscover_network", AsyncMock(return_value=[moved])), \
             patch.object(discovery, "remember_devices") as remember, patch("builtins.print"):
            self.assertEqual(discovery.main(), 0)
            remember.assert_called_once_with([moved])

    def test_periodic_scan_finds_new_tv_while_current_tv_is_available(self):
        current = {"name": "Current", "identifier": "AA:BB", "deviceIdentifier": "AA:BB", "model": "AppleTV", "address": "10.0.0.5"}
        new = {"name": "Bedroom", "identifier": "CC:DD", "deviceIdentifier": "CC:DD", "model": "AppleTV", "address": "10.0.0.9"}
        with patch.object(discovery, "capture", return_value=types.SimpleNamespace(stdout="", returncode=0)), \
             patch.object(discovery, "load_known_devices", return_value={"AA:BB": "10.0.0.5"}), \
             patch.object(discovery, "discover_known_devices", AsyncMock(return_value=[current])), \
             patch.object(discovery, "rediscover_network", AsyncMock(return_value=[current, new])), \
             patch.object(discovery, "remember_devices") as remember, patch("builtins.print"):
            self.assertEqual(discovery.main(scan_network=True), 0)
            remember.assert_called_once_with([current, new])


if __name__ == "__main__":
    unittest.main()
