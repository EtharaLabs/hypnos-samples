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
# Make the log directory root-only before any agent code runs.
mkdir -p "$LOGS"
chown 0:0 "$LOGS"
chmod 0755 "$LOGS"
find "$LOGS" -mindepth 1 -maxdepth 1 ! -name test-stdout.txt -exec rm -rf {} +
G=/tmp/grade
W=$G/work
R=$G/raw
mkdir -p "$LOGS"
rm -rf "$G" /home/tester
install -d -m 0755 "$G"
install -d -m 0700 "$R" "$R/cases"
install -d -o 20003 -g 20003 -m 0755 "$W" /home/tester
start=$(date +%s)
survivors=0
TOOLBIN=$(dirname "$(cd / && rustup which cargo)")
# Test-support crates come from the pristine base like every tests/ directory.
SUPPORT=" biome_test_utils biome_formatter_test tests_macros "

reap() {
  local live=0
  pkill -KILL -u 20003 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    live=$(ps -u 20003 -o stat= 2>/dev/null | grep -vc '^Z')
    [ "$live" -eq 0 ] && return 0
    sleep 1
    pkill -KILL -u 20003 2>/dev/null
  done
  survivors=$((survivors + live))
}

# run_stage NAME SECONDS COMMAND...: writes $R/NAME.out, .err and .rc.
run_stage() {
  local name=$1 limit=$2
  shift 2
  timeout -s KILL "$limit" setsid -w setpriv --reuid=20003 --regid=20003 --clear-groups \
    env -i PATH="$TOOLBIN:/usr/bin:/bin" HOME=/home/tester LANG=C.UTF-8 \
    CARGO_HOME=/usr/local/cargo CARGO_NET_OFFLINE=true "$@" >"$R/$name.out" 2>"$R/$name.err"
  echo $? >"$R/$name.rc"
  reap
}

# Graded tree: pristine base and hidden tests, with the agent's Rust sources copied over it.
cp -a /opt/base-src "$W/src"
for crate in /opt/base-src/crates/*/; do
  name=$(basename "$crate")
  case "$SUPPORT" in *" $name "*) continue ;; esac
  rm -rf "$W/src/crates/$name/src"
  if [ -d "/app/crates/$name/src" ] && [ ! -L "/app/crates/$name/src" ]; then
    cp -r "/app/crates/$name/src" "$W/src/crates/$name/src"
  fi
done
rm -rf "$W/src/xtask/codegen/src"
if [ -d /app/xtask/codegen/src ] && [ ! -L /app/xtask/codegen/src ]; then
  cp -r /app/xtask/codegen/src "$W/src/xtask/codegen/src"
fi
find "$W/src/crates"/*/src "$W/src/xtask/codegen/src" -type l -delete 2>/dev/null
chown -R 20003:20003 "$W"

{
  for crate in /opt/base-src/crates/*/; do
    name=$(basename "$crate")
    case "$SUPPORT" in *" $name "*) continue ;; esac
    diff -ruN "/opt/base-src/crates/$name/src" "$W/src/crates/$name/src"
  done
  diff -ruN /opt/base-src/xtask/codegen/src "$W/src/xtask/codegen/src"
} 2>/dev/null | sed -e "s#/opt/base-src/#a/#g" -e "s#$W/src/#b/#g" | cap_diff >"$LOGS/submission.diff"

# One cargo invocation builds and runs every test target; a second would rebuild the analyzer.
run_stage test 3600 bash /grading/stage_test.sh

# R6 and R9: each authored case is a biome lint run in its own copy of the case directory.
bin=$W/src/target/debug/biome
for case in /grading/cases/*/; do
  id=$(basename "$case")
  cp -r "$case" "$W/case-$id"
  chown -R 20003:20003 "$W/case-$id"
  run_stage "cases/$id" 120 bash -c 'cd "$1" && exec "$2" lint --colors=off --max-diagnostics=none .' \
    case "$W/case-$id" "$bin"
done

grep -v '^{' "$R/test.out" | tail -c 600000 >"$LOGS/test.log" 2>/dev/null

python3 /grading/summarize.py --raw "$R" --grading /grading --logs "$LOGS" \
  --survivors "$survivors" --elapsed "$(( $(date +%s) - start ))"
