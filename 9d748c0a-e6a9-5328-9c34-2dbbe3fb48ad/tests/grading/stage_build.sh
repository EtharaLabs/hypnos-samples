#!/bin/bash
# Build stage, uid 20003: install the test modules and their dependencies offline, without tests.
set -uo pipefail
cd /tmp/grade/work/src
exec mvn -o -B -T 8 -Dmaven.repo.local=/tmp/grade/work/m2 \
  -pl kubernetes-model-generator/kubernetes-model-common,generator-annotations,kubernetes-client-api,crd-generator/api-v2,crd-generator/test \
  -am install -Dmaven.test.skip=true
