#!/bin/bash
# Build stage, uid 10003. Compiles every workspace test target and the binaries the integration tests
# use. Stdout carries cargo's artifact records, which map each test executable to its package and target.
set -uo pipefail
cd /tmp/grade/work/src
exec cargo test --workspace --no-run --color never --message-format=json-render-diagnostics
