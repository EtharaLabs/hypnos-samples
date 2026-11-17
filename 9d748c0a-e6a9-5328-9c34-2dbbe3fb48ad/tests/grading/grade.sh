#!/bin/bash
# Orchestrator: each stage runs isolated as uid 20003; exit 0 opens the reward gate, 3 closes it.
set -uo pipefail
LOGS=/logs/verifier
# Submission diff for the judge: lines cut at 4,000 bytes, total at 600,000, valid UTF-8.
cap_diff() {
  python3 -c '
import sys
total, limit = 0, 600000
out = sys.stdout.buffer
for line in sys.stdin.buffer:
    body = line.rstrip(b"\n")
    if len(body) > 4000:
        body = body[:4000] + b" [line cut at 4000 bytes]"
    chunk = body + b"\n"
    if total + len(chunk) > limit:
        break
    out.write(chunk.decode("utf-8", "ignore").encode("utf-8"))
    total += len(chunk)
'
}
G=/tmp/grade
W=$G/work
R=$G/raw
TH=/tmp/tester-home
# Make the log directory root-only before any agent code runs.
mkdir -p "$LOGS"
chown 0:0 "$LOGS"
chmod 0755 "$LOGS"
find "$LOGS" -mindepth 1 -maxdepth 1 ! -name test-stdout.txt -exec rm -rf {} +
printf '0\n' >"$LOGS/reward.txt"
rm -rf "$G" "$TH"
install -d -m 0755 "$G" "$W"
install -d -m 0700 "$R"
install -d -o 20003 -g 20003 -m 0755 "$TH" "$TH/tmp"
start=$(date +%s)
survivors=0

reap() {
  local live=0
  pkill -KILL -u 20003 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    live=$(ps -u 20003 -o stat= 2>/dev/null | grep -vc '^Z')
    [ "$live" -eq 0 ] && break
    sleep 1
    pkill -KILL -u 20003 2>/dev/null
  done
  survivors=$((survivors + live))
  find /tmp /var/tmp /dev/shm -xdev -mindepth 1 \( -path "$G" -prune \) -o \( -user 20003 -prune -exec rm -rf {} + \) 2>/dev/null
  rm -rf "$TH"
  install -d -o 20003 -g 20003 -m 0755 "$TH" "$TH/tmp"
}

# run_stage NAME SECONDS COMMAND...: writes $R/NAME.out, .err, .rc and .seconds.
run_stage() {
  local name=$1 limit=$2 began
  shift 2
  began=$(date +%s)
  timeout -s KILL "$limit" setsid -w setpriv --reuid=20003 --regid=20003 --clear-groups \
    env -i PATH=/usr/bin:/bin HOME="$TH" LANG=C.UTF-8 TZ=UTC TMPDIR="$TH/tmp" \
    MAVEN_OPTS="-Djava.io.tmpdir=$TH/tmp" "$@" >"$R/$name.out" 2>"$R/$name.err"
  echo $? >"$R/$name.rc"
  echo $(( $(date +%s) - began )) >"$R/$name.seconds"
  reap
}

# Graded tree: pristine base and hidden tests, with the agent's src/main/java trees over it.
cp -a /opt/base-src "$W/src"
while read -r module; do
  [ -n "$module" ] || continue
  rm -rf "${W:?}/src/$module/src/main/java"
  if [ -d "/app/$module/src/main/java" ] && [ ! -L "/app/$module/src/main/java" ] && [ ! -L "/app/$module/src/main" ] \
    && [ ! -L "/app/$module/src" ] && [ ! -L "/app/$module" ]; then
    mkdir -p "$W/src/$module/src/main"
    cp -r --no-dereference "/app/$module/src/main/java" "$W/src/$module/src/main/java" 2>/dev/null
  fi
done </grading/private/modules.txt
find "$W/src" -xdev ! -type f ! -type d -delete 2>/dev/null
cp -a /opt/m2 "$W/m2"

while read -r module; do
  [ -n "$module" ] || continue
  diff -ruN "/opt/base-src/$module/src/main/java" "$W/src/$module/src/main/java"
done </grading/private/modules.txt 2>/dev/null | sed -e "s#/opt/base-src/#a/#g" -e "s#$W/src/#b/#g" | cap_diff >"$LOGS/submission.diff"

# Build stage: install every graded module into the private repository, without running tests.
chown -R 20003:20003 "$W/src" "$W/m2"
run_stage build 1800 bash /grading/stage_build.sh
chown -R 0:0 "$W/src" "$W/m2"
chmod -R go-w "$W/src" "$W/m2"

# One Maven run per test module; root then saves its Surefire reports and re-owns the module.
while read -r name module; do
  [ -n "$name" ] || continue
  chown -R 20003:20003 "$W/src/$module"
  run_stage "test-$name" 1500 bash /grading/stage_test.sh "$module"
  install -d -m 0700 "$R/reports-$name"
  for report in "$W/src/$module/target/surefire-reports"/TEST-*.xml; do
    [ -f "$report" ] && [ ! -L "$report" ] || continue
    head -c 16000000 "$report" >"$R/reports-$name/$(basename "$report")" 2>/dev/null
  done
  chown -R 0:0 "$W/src/$module"
  chmod -R go-w "$W/src/$module"
  tail -c 300000 "$R/test-$name.out" >"$LOGS/test-$name.out.log" 2>/dev/null
  tar -C "$R" -czf "$LOGS/reports-$name.tar.gz" "reports-$name" 2>/dev/null
done </grading/private/test-modules.txt

for f in build.out build.err; do
  tail -c 300000 "$R/$f" >"$LOGS/$f.log" 2>/dev/null
done

python3 /grading/summarize.py --raw "$R" --grading /grading --logs "$LOGS" \
  --survivors "$survivors" --elapsed "$(( $(date +%s) - start ))"
