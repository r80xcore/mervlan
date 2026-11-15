#!/bin/sh
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ -f "$DIR/SHA256SUMS" ] || { echo 'No hash list' >&2; exit 1; }
(cd "$DIR" && sha256sum -c SHA256SUMS)
