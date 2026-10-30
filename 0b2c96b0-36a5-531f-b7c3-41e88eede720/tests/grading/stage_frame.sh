#!/bin/bash
# Frame stage, uid 10003. Runs the whole workspace suite, the hidden upstream tests among it, with
# cargo's target headers and every test binary's output in one stream.
set -uo pipefail
cd /tmp/grade/work/src
exec cargo test --workspace --no-fail-fast --color never 2>&1
