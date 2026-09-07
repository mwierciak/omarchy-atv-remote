#!/usr/bin/env python3
"""Start the versioned backend if needed and send it one command."""

import fcntl
import hashlib
import json
import ipaddress
import stat
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from command_input import read_command
from safe_io import runtime_directory, open_file

if len(sys.argv) == 4:
    address, command, daemon = sys.argv[1:4]
    if command.startswith('text_append:'):
        raise ValueError('Text commands must be read from stdin')
elif len(sys.argv) == 3:
    address, daemon = sys.argv[1:3]
    command = read_command(sys.stdin.buffer)
else:
    raise ValueError("An address, command source, and daemon are required")
address = str(ipaddress.IPv4Address(address))
runtime = runtime_directory()
daemon_hash = hashlib.sha256(b"".join(Path(daemon).with_name(name).read_bytes() for name in ("remote_daemon.py", "backend_errors.py", "safe_io.py", "secure_storage.py", "runner.py"))).hexdigest()[:10]
address_hash = hashlib.sha256(address.encode()).hexdigest()[:12]
socket_path = runtime / f"omarchy-appletv-{address_hash}-{daemon_hash}.sock"
lock_path = runtime / f"omarchy-appletv-{address_hash}.lock"
RETRYABLE = (FileNotFoundError, ConnectionRefusedError, ConnectionResetError, BrokenPipeError, socket.timeout)


def send(request_command, watch=False, emit=True, timeout=15):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        info = socket_path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise PermissionError("Unsafe socket path")
        client.settimeout(40 if watch else timeout)
        client.connect(str(socket_path))
        client.sendall((json.dumps({"command": request_command}) + "\n").encode())
        stream = client.makefile()
        if watch:
            while True:
                line = stream.readline(16385)
                if not line:
                    return
                if len(line) > 16384 or not line.endswith("\n"):
                    raise ValueError("Oversized backend response")
                print(line, end="", flush=True)
            return
        line = stream.readline(16385)
        if len(line) > 16384 or (line and not line.endswith("\n")):
            raise ValueError("Oversized backend response")
        if not line:
            raise ConnectionResetError("Apple TV backend closed without a response")
        response = json.loads(line)
        if emit:
            print(json.dumps(response), flush=True)
        if not response.get("ok"):
            raise SystemExit(1)


def ensure_backend():
    deadline = time.monotonic() + 7
    with os.fdopen(open_file(lock_path, os.O_CREAT | os.O_RDWR), "a+") as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Backend startup lock timed out")
                time.sleep(.05)
        try:
            send("ping", emit=False, timeout=.5)
            return
        except RETRYABLE:
            if socket_path.exists():
                info = socket_path.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                    raise PermissionError("Unsafe socket path")
                socket_path.unlink()
        # The daemon monitors the launching shell's PID/start time and has a
        # hard one-hour lifetime. No filesystem log or shared-temp fallback.
        child = subprocess.Popen(
            [sys.executable, "-E", "-s", "-B", str(Path(daemon).with_name("runner.py")), "daemon", sys.executable, "-E", "-s", "-B", daemon, address, str(socket_path)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            while time.monotonic() < deadline:
                try:
                    send("ping", emit=False, timeout=.5)
                    return
                except RETRYABLE:
                    if child.poll() is not None:
                        raise RuntimeError("Backend exited during startup")
                    time.sleep(.05)
            raise TimeoutError("Backend startup timed out")
        except BaseException:
            child.terminate()
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            raise


try:
    ensure_backend()
    send(command, watch=command == "keyboard_watch")
except Exception as error:
    offline = isinstance(error, (OSError, TimeoutError))
    print(json.dumps({"ok": False, "state": "offline" if offline else "error",
                      "error": "Apple TV is offline or unreachable" if offline else "Could not start the Apple TV backend"}), flush=True)
    sys.exit(1)
