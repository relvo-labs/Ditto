"""Ditto whole-disk installer core (#221).

The installer copies the byte ranges of one finished, pristine-scanned Ditto
disk image onto a single confirmed target disk. It never mounts or edits the
target file systems; the only bytes it authors are the GPT and zeroed wipe
regions. Frontends (graphical or text) drive :mod:`session`; they cannot name
paths, offsets or payload files themselves.
"""

SECTOR = 512
MIB = 1024 * 1024
