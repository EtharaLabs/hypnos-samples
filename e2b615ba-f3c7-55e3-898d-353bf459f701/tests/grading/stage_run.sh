#!/bin/bash
# Run stage, uid 20003: run one test executable with JSON events; test logging stays at warn.
set -uo pipefail
cd "$2" || exit 2
export CARGO_MANIFEST_DIR="$2"
export RUST_LOG=warn
exec "$1" -Z unstable-options --format json --show-output --test-threads=8 </dev/null
