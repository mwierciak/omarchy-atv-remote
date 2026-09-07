# Security policy

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** link for this repository when it
is available. Do not include credentials, pairing data, or exploit details in a
public issue. If private reporting is unavailable, contact the maintainer through
their GitHub profile before publishing details.

Include the affected commit, reproduction steps, impact, and any suggested fix.

## Security boundaries

This plugin runs as the logged-in user inside Omarchy Shell and can control a
paired Apple TV. Its local files and Unix sockets protect against other local
users, but they are not a sandbox from other processes running under the same
account. Pairing credentials are stored by pyatv in `~/.pyatv.conf` with private
file permissions.

The active LAN scan is disabled by default. Enabling it permits bounded TCP
probes on directly connected private Ethernet and Wi-Fi networks.
