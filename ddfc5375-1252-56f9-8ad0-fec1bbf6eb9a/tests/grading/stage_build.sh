#!/bin/bash
# Build stage, uid 20003: compile the minifier's test executables offline.
set -uo pipefail
cd /tmp/grade/work/src
exec cargo test --offline --locked --no-run --color never --message-format=json-render-diagnostics -p oxc_minifier
