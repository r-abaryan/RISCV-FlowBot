#!/bin/sh
# Reproducible Yosys install for an Alpine (musl) sandbox WITHOUT touching the system packages.
# Installs Yosys + its runtime deps (python3, tcl, abc, ...) into a private root: $YROOT (default /opt/yroot).
# Source: Alpine edge/testing package yosys-0.68-r0 (Yosys 0.68+post, git c12172fb).
# Needs root, network, ~300 MB disk. Takes ~1-2 min. Idempotent.
# Afterwards:  . /opt/yroot/env.sh   (puts `yosys` on PATH)
set -e
YROOT=${YROOT:-/opt/yroot}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine/edge}
# sha256 of the yosys-0.68-r0.apk that was verified in this project (2026-10-13).
# NOTE: Alpine edge is rolling and removes old files; if the pin no longer matches, see docs/19.
PIN_SHA256=1f90663ec1751555db1beba3326c3fc3803b80de9f5ea57d6383760cb6696d44
# WARNING: PIN_SHA256 is documentation only; apk verifies signatures via its keys, this script does NOT compare the hash.
if [ ! -x "$YROOT/usr/bin/yosys" ]; then
  mkdir -p "$YROOT"
  apk add --root "$YROOT" --initdb --no-scripts --no-cache \
    --keys-dir /etc/apk/keys \
    --repository "$MIRROR/main" --repository "$MIRROR/testing" yosys
fi
# HOST MODIFICATION: creates symlink /usr/bin/abc outside $YROOT (Yosys hard-codes that path). Remove with: rm /usr/bin/abc
# Yosys hard-codes /usr/bin/abc as its ABC executable. abc only needs musl, so a symlink is enough.
if [ ! -e /usr/bin/abc ]; then ln -s "$YROOT/usr/bin/abc" /usr/bin/abc; fi
cat > "$YROOT/env.sh" <<ENV
# source me:  . $YROOT/env.sh
export LD_LIBRARY_PATH=$YROOT/usr/lib:$YROOT/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
export PYTHONHOME=$YROOT/usr
export PATH=$YROOT/usr/bin:\$PATH
ENV
. "$YROOT/env.sh"
yosys -V
yosys -p 'help synth_ecp5' >/dev/null 2>&1 && echo "synth_ecp5 available"
echo "installed package versions:"; grep -E '^(P|V):' "$YROOT/lib/apk/db/installed" | paste - - | tr '\t' ' ' | grep -E 'P:(yosys|abc|python3|tcl|musl|libstdc\+\+|libgcc) '
echo "expected apk sha256 (informational): $PIN_SHA256"
