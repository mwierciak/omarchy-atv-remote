"""Single hash-locked installation and launch boundary for every entry point."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from safe_io import directory, open_file, read_file, atomic_write

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'requirements.lock'
DIGEST = hashlib.sha256(LOCK.read_bytes()).hexdigest()[:16]
DATA = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'omarchy/apple-tv-remote'
VENV = DATA / f'venv-{sys.version_info.major}.{sys.version_info.minor}-{DIGEST}'


def installed():
    try:
        os.close(directory(DATA))
        os.close(directory(VENV))
        return read_file(VENV / '.complete', 128).strip() == DIGEST
    except FileNotFoundError:
        return False


def install():
    os.close(directory(DATA))
    fd = open_file(DATA / 'install.lock', os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if installed():
            return
        os.close(directory(VENV))
        subprocess.run(['/usr/bin/python', '-I', '-m', 'venv', '--copies', str(VENV)], check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(VENV / 'bin/python'), '-I', '-m', 'pip', '--isolated', '--disable-pip-version-check',
                        'install', '--no-cache-dir', '--only-binary=:all:', '--require-hashes',
                        '--index-url', 'https://pypi.org/simple', '-r', str(LOCK)],
                       check=True, timeout=240, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(VENV / 'bin/python'), '-I', '-m', 'pip', 'check'], check=True, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atomic_write(VENV / '.complete', DIGEST + '\n')
    finally:
        os.close(fd)


def main():
    mode, *args = sys.argv[1:]
    if mode in ('install', 'pair') and not installed():
        print(json.dumps({'event':'progress', 'message':'Installing Apple TV support…'}), flush=True)
        install()
    if mode == 'install':
        return 0
    if not installed():
        print(json.dumps({'ok':False, 'state':'setup', 'error':'Setup required', 'devices':[]}), flush=True)
        return 127
    executable = str(VENV / 'bin/python')
    script = {'discover':'discovery.py', 'remote':'remote_client.py',
              'remote-stdin':'remote_client.py', 'pair':'pairing.py'}.get(mode)
    if script is None:
        raise ValueError('Unsupported runtime mode')
    os.execv(executable, [executable, '-E', '-s', '-B', str(ROOT / 'bin' / script), *args])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception:
        print(json.dumps({'ok':False, 'state':'setup', 'event':'error', 'error':'Apple TV installation failed or its paths are unsafe.',
                          'message':'Apple TV installation failed or its paths are unsafe.'}), flush=True)
        sys.exit(1)
