"""Read one bounded command frame from stdin without exposing it in argv."""
import json


def read_command(stream, limit=1024):
    line = stream.readline(limit + 1)
    if not line or len(line) > limit or not line.endswith(b'\n'):
        raise ValueError('Missing or oversized command input')
    request = json.loads(line)
    command = request.get('command') if isinstance(request, dict) else None
    if not isinstance(command, str) or not command or len(command) > 512:
        raise ValueError('A bounded string command is required')
    return command
