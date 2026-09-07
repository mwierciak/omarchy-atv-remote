# Apple TV Remote for Omarchy

A native Omarchy bar panel backed by [pyatv](https://pyatv.dev/).

Dependencies are Python 3.13 or 3.14, Avahi (`avahi-browse`), and iproute2
(`ip`), as provided by Omarchy. The pairing flow installs pyatv and its complete
transitive dependency set from the committed `requirements.lock`. Every wheel
is pinned by version and SHA-256; source builds and unverified dependencies are
rejected. Installation uses the system Python and a private versioned virtual
environment under `~/.local/share/omarchy/apple-tv-remote/`.

![Apple TV Remote panel](preview.png)

## Install

```bash
omarchy plugin add https://github.com/mwierciak/omarchy-atv-remote
```

The plugin is initially disabled so you can review the checked-out code before
enabling it. For an immutable installation, detach the checkout at the full
commit SHA you reviewed; Omarchy plugin updates otherwise follow the repository's
moving default branch. Enable the plugin after review, add its widget to the
Omarchy bar, and open the remote icon to continue.

## Pair

1. Choose **Manage Apple TV** to select a TV or enter its IP address.
   The button says **Pair [TV name]** only when pairing is needed, or **Set up
   Apple TV** when the backend needs installation. Connected TVs show **Pair again**
   inside settings if you need to replace their pairing. The computer and TV must share a network.
2. Choose **Start pairing**. Enter each PIN shown on the TV directly in the panel.
   Companion enables remote control; AirPlay supports metadata. Installation,
   progress, errors, and cancellation are handled without opening a terminal.
3. Choose **Done** to return to the remote. Changing TVs only requires selecting
   a different device in the list; already-paired TVs do not need pairing again.

Pairing displays prompts on the TV. Use it when those watching can enter the PIN.
Closing the panel or choosing **Cancel** ends the active pairing attempt.
The terminal `bin/setup` installs the same locked backend; pairing itself is
handled in the panel.

Pairing credentials are stored by pyatv in `~/.pyatv.conf`.

## Keyboard remote

The header names the current TV. Its row is highlighted with a checkmark and
**Connected** (or **Selected** until the connection succeeds). Hover a TV row
to see its IP address.

Open the pop-out and use:

- Arrow keys — navigate
- Enter — select
- Backspace — back/menu
- Space — play/pause
- `H` — home
- `,` / `.` — volume down / up
- Escape — close the remote

Use the cog beside **Keyboard Remote** to customize shortcuts. Click an action,
then press its new key (optionally with Ctrl, Alt, Shift, or Super). Duplicate
bindings are rejected; **Restore defaults** resets them. Escape is reserved for
closing/cancelling. Settings persist with the widget and survive TV selection.
Text input in a TV search field continues to take precedence over shortcuts.

Keyboard controls are active only while the remote is open and its panel has
keyboard focus. Moving focus away stops forwarding keys and clears unsent
keystrokes. Pairing form input is never forwarded as remote keystrokes. Escape closes the
remote, or cancels the pairing form.

Now Playing shows the title, playback state, series, season/episode, secondary
metadata (such as an episode title), and elapsed/total time when the TV provides
them. Apps that embed episode details in the artist field are also supported.
Unavailable fields are hidden; episode information is never guessed.
The playback clock advances every second while playing, caps at the duration,
and resynchronizes with TV metadata every 10 seconds. Paused playback does not
advance. Play/pause commands also request a fresh status immediately. Missing metadata does not affect remote control. Status separates
searching, unreachable devices, missing/invalid pairing, and other errors.

Compact feedback at the upper right of the header shows each keystroke and
the action sent to Apple TV. It maintains
a persistent Companion connection, so repeated navigation commands do not
reconnect for every keypress.

When tvOS focuses a search or login field, the panel detects it automatically
and switches to text-input mode. Printable keys and Space type directly into
the Apple TV field; Backspace deletes text. The normal remote mappings return
as soon as the field loses focus. The pop-out shows the text sent during the
current typing burst, reflects Backspace edits, and clears the preview shortly
after typing stops. The preview is masked by default; disable `maskTextPreview`
in the widget settings only when displaying typed characters is acceptable.
Typed text is framed over the helper's standard input and the private backend
socket, never command-line arguments.

The selected Apple TV is stored by its stable device identifier, so changing
DHCP addresses does not require selecting or pairing it again. Backend sessions
shut down after ten idle minutes or when the plugin is unloaded. A supervisor
also bounds their total lifetime to one hour; they reconnect automatically.
Finite helper processes have wall-clock, memory, file-descriptor and output
limits, and cancelling pairing terminates its installation/process group.

Discovered TVs' identifiers and last known IP addresses are cached in
`~/.local/state/omarchy/apple-tv-remote/devices.json` (or under `XDG_STATE_HOME`).
If multicast discovery misses a saved TV, the panel tries its address directly
and verifies its identifier before displaying it. A TV must respond to appear;
cached entries are never presented as live devices without checking them.
If a saved address no longer works, you can opt into bounded scans of directly
connected private IPv4 Ethernet or Wi-Fi LANs with `networkScan` in the widget
settings. VPN and virtual interfaces are not actively scanned. Devices are
selected by stable identifier, so a changed address does not change the selected
TV. The available-TV list refreshes automatically every minute, including while
the panel is closed. With `networkScan` enabled, a broader LAN scan runs at
startup and every five minutes to find new TVs even when multicast discovery is
blocked and the selected TV is still reachable. Scans pause while
managing/pairing a TV; overlapping scans are skipped.
Connection/metadata refresh every 10 seconds only while the remote is open.
Large networks are limited to the local /24, and only conventional physical
Ethernet or Wi-Fi interface names are eligible.

The panel can also be scripted with Omarchy Shell IPC, for example:

```bash
omarchy-shell anders.appletv-remote playPause
omarchy-shell anders.appletv-remote home
```

## Local state and limits

The runtime uses an owned private directory under `XDG_RUNTIME_DIR` (normally
`/run/user/UID`), with no shared `/tmp` fallback. Cache, lock, and credential
reads reject symlinks and inappropriate ownership; cache/credential writes are
atomic and private. Existing pyatv pairing credentials remain compatible.
Discovery accepts at most 32 TVs with bounded metadata. The unsent command
queue is limited to 32 commands; network-derived display text is plain text.
The backend does not write persistent logs containing device or typed content.

## Remove

```bash
omarchy plugin remove anders.appletv-remote
```

Omarchy removes the plugin itself. Pairing credentials in `~/.pyatv.conf` and
the isolated backend under `~/.local/share/omarchy/apple-tv-remote/` are left
in place intentionally so removal never deletes user data without consent.

## License

The plugin is MIT licensed. The Apple TV logo from Simple Icons and the legacy
Siri Remote SVG are CC0; sources and license notices are in `assets/LICENSE.txt`.
