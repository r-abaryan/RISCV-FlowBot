#!/bin/sh
# Verify per-file SHA-256 of M9b study episode files.
cd "$(dirname "$0")/../results/m9b" && sha256sum -c >/dev/null study_manifest.sha256 && echo "OK: $(wc -l < study_manifest.sha256) files verified"
