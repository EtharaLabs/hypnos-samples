#!/bin/bash
# Test stage, uid 20003: run one module's tests offline; excludes.txt lists skipped tests.
set -uo pipefail
cd /tmp/grade/work/src
exec mvn -o -B -Dmaven.repo.local=/tmp/grade/work/m2 -pl "$1" test \
  -Dmaven.test.failure.ignore=true -Dmaven.test.redirectTestOutputToFile=true \
  -Dsurefire.excludesFile=/grading/excludes.txt
