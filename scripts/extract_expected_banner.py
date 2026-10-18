#!/usr/bin/env python3
"""Extract the UART boot banner bytes from the committed firmware hex (little-endian 32-bit words, one per line).
Usage: extract_expected_banner.py [hex] [out.bin]   Prints length and sha256 to stderr. Exit 1 unless exactly one
banner start is found and it is NUL-terminated with length 148 (the length documented in docs/47)."""
import hashlib, struct, sys
hexf = sys.argv[1] if len(sys.argv) > 1 else "sw/firmware/robot_nav.hex"
out = sys.argv[2] if len(sys.argv) > 2 else "expected_banner.bin"
b = b"".join(struct.pack("<I", int(t, 16)) for t in open(hexf).read().split())
start = b"\n=== RISC-V Mobile Robot Navigation SoC Online ==="
if b.count(start) != 1: sys.exit("banner start found %d times" % b.count(start))
i = b.find(start); j = b.find(b"\0", i)
if j < 0: sys.exit("no NUL terminator")
msg = b[i:j]
open(out, "wb").write(msg)
print("bytes=%d sha256=%s" % (len(msg), hashlib.sha256(msg).hexdigest()), file=sys.stderr)
if len(msg) != 148: sys.exit("expected 148 bytes, got %d" % len(msg))
