"""Frontend ↔ backend wire format: one JSON object per line, fixed actions only.

A frontend can never name a device, path, offset, payload file or command;
the only free-form value it sends back is an opaque token the backend issued.
"""

import json
import re

MAX_REQUEST = 4096
MAX_RESPONSE = 256 * 1024
TOKEN = re.compile(r"[A-Za-z0-9_-]{1,64}")
ACTIONS = {
    "state": (),       # includes progress and the final result
    "list": (),
    "select": ("token",),
    "back": (),
    "confirm": ("token",),   # re-checks the disk and starts writing
    "cancel": (),
    "reboot": (),
}


class ProtocolError(ValueError):
    def __init__(self, code="invalid_request"):
        super().__init__(code)
        self.code = code


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def parse_request(line):
    if not isinstance(line, bytes) or len(line) > MAX_REQUEST or not line.endswith(b"\n"):
        raise ProtocolError()
    try:
        request = json.loads(line.decode("utf-8"), object_pairs_hook=_unique,
                             parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProtocolError() from error
    if not isinstance(request, dict) or not isinstance(request.get("action"), str):
        raise ProtocolError()
    fields = ACTIONS.get(request["action"])
    if fields is None or set(request) != {"action", *fields}:
        raise ProtocolError()
    if any(not isinstance(request[field], str) or not TOKEN.fullmatch(request[field]) for field in fields):
        raise ProtocolError()
    return request


def encode(message):
    data = (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(data) > MAX_RESPONSE:
        raise ValueError("response too large")
    return data


def request_line(action, **fields):
    return encode({"action": action, **fields})
