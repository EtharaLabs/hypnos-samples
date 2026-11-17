#!/bin/bash
# Test stage, uid 20003: one cargo invocation builds and runs every workspace test target.
set -uo pipefail
cd /tmp/grade/work/src
export CI=true INSTA_UPDATE=no
exec cargo test --workspace --lib --bins --tests --no-fail-fast --color never \
  --message-format=json-render-diagnostics 2>&1
