#!/bin/bash
# Build stage, uid 20003: compile every test executable of the graded packages offline.
set -uo pipefail
cd /tmp/grade/work/src
exec cargo test --offline --locked --no-run --color never --message-format=json-render-diagnostics \
  -p swc_ecma_transforms_typescript -p swc_ecma_transforms_base -p swc_ecma_utils -p swc_atoms
