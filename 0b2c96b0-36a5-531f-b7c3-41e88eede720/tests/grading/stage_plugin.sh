#!/bin/bash
# Plugin stage, uid 10003. The example plugin the R6 cases load, built as the test harness builds it.
set -uo pipefail
cd /tmp/grade/work/src
exec cargo build --package nu_plugin_example --color never
