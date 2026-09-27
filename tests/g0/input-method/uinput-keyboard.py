#!/usr/bin/env python3
"""A kernel keyboard for the C-08 automated login-session check.

stipc's virtual keyboard never produced a composition (input-method report
§3): it may bypass the input-method keyboard grab. This creates a real evdev
device through /dev/uinput instead, so libinput and Wayfire see the same kind
of device a USB keyboard is. It is still not a person at a physical keyboard,
which is why the result it produces is not EX-08 evidence.

Reads one command per line on stdin and answers "ok" after each:

    type <lowercase letters, digits and spaces>
    key <name>            e.g. key backspace
    combo <a+b[+c]>       e.g. combo ctrl+shift+v
    sleep <seconds>

Needs write access to /dev/uinput (run it with sudo in the development VM).
"""
import fcntl
import os
import struct
import sys
import time

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0
BUS_USB = 0x03

KEYS = {"esc": 1, "backspace": 14, "tab": 15, "enter": 28, "ctrl": 29, "shift": 42,
        "alt": 56, "space": 57, "minus": 12, "equal": 13}
KEYS.update({str(n): 2 + (n - 1) % 10 for n in range(1, 11)})
KEYS["0"] = 11
for row, first in (("qwertyuiop", 16), ("asdfghjkl", 30), ("zxcvbnm", 44)):
    for offset, letter in enumerate(row):
        KEYS[letter] = first + offset


def emit(fd, kind, code, value):
    now = time.time()
    os.write(fd, struct.pack("llHHi", int(now), int(now % 1 * 1_000_000), kind, code, value))


def press(fd, codes):
    for code in codes:
        emit(fd, EV_KEY, code, 1)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.02)
    for code in reversed(codes):
        emit(fd, EV_KEY, code, 0)
        emit(fd, EV_SYN, SYN_REPORT, 0)
        time.sleep(0.02)
    # A human typist is not faster than this; the input method and the
    # compositor both see each key as a separate frame.
    time.sleep(0.06)


def main():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in set(KEYS.values()):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    setup = struct.pack("HHHH80sI", BUS_USB, 0x1D6B, 0x0C08, 1, b"Ditto C-08 kernel keyboard", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    # libinput adds the device on the udev event; keys before that are lost.
    time.sleep(1.5)
    print("ready", flush=True)
    try:
        for line in sys.stdin:
            verb, _, argument = line.strip().partition(" ")
            if verb == "type":
                for char in argument:
                    press(fd, [KEYS["space" if char == " " else char]])
            elif verb == "key":
                press(fd, [KEYS[argument]])
            elif verb == "combo":
                press(fd, [KEYS[name] for name in argument.split("+")])
            elif verb == "sleep":
                time.sleep(float(argument))
            elif verb:
                print(f"unknown command: {verb}", file=sys.stderr, flush=True)
                return 2
            print("ok", flush=True)
    finally:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
