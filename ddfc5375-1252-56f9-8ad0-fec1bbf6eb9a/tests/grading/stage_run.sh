#!/bin/bash
# Run stage, uid 20003: run one test executable from its package directory with JSON events.
set -uo pipefail
cd "$2" || exit 2
export RUSTC_BOOTSTRAP=1
exec "$1" -Z unstable-options --format json --show-output --test-threads=8
