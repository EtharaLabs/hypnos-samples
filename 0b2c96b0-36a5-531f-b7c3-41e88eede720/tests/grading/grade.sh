#!/bin/bash
# Root orchestrator. Every stage that compiles or runs the agent's code runs as uid 10003 in its own
# session with a cleared environment, writing only to files root opened in a directory uid 10003
# cannot enter; after each stage every uid 10003 process is killed and confirmed gone. Exit 0 opens
# the reward gate, 3 closes it.
set -uo pipefail
LOGS=/logs/verifier
G=/tmp/grade
W=$G/work
R=$G/raw
mkdir -p "$LOGS"
rm -rf "$G" /tmp/tester-home
install -d -m 0755 "$G"
install -d -m 0700 "$R" "$R/cases"
install -d -o 10003 -g 10003 -m 0755 "$W" /tmp/tester-home
start=$(date +%s)
survivors=0
TOOLBIN=$(dirname "$(cd / && rustup which cargo)")

reap() {
  local live=0
  pkill -KILL -u 10003 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    live=$(ps -u 10003 -o stat= 2>/dev/null | grep -vc '^Z')
    [ "$live" -eq 0 ] && return 0
    sleep 1
    pkill -KILL -u 10003 2>/dev/null
  done
  survivors=$((survivors + live))
}

# run_stage NAME SECONDS COMMAND...: stdout to $R/NAME.out, stderr to $R/NAME.err, status to $R/NAME.rc.
run_stage() {
  local name=$1 limit=$2
  shift 2
  timeout -s KILL "$limit" setsid -w setpriv --reuid=10003 --regid=10003 --clear-groups \
    env -i PATH="$TOOLBIN:/usr/bin:/bin" HOME=/tmp/tester-home LANG=C.UTF-8 \
    CARGO_HOME=/usr/local/cargo CARGO_NET_OFFLINE=true "$@" >"$R/$name.out" 2>"$R/$name.err"
  echo $? >"$R/$name.rc"
  reap
}

# The pristine base with the hidden tests, and the agent's Rust sources over it: crates/*/src but
# crates/nu-test-support, and src/. A source directory the agent removed is removed; symlinks are
# dropped.
cp -a /opt/base-src "$W/src"
for crate in /opt/base-src/crates/*/; do
  name=$(basename "$crate")
  [ "$name" = nu-test-support ] && continue
  rm -rf "$W/src/crates/$name/src"
  if [ -d "/app/crates/$name/src" ] && [ ! -L "/app/crates/$name/src" ]; then
    cp -r "/app/crates/$name/src" "$W/src/crates/$name/src"
  fi
done
rm -rf "$W/src/src"
if [ -d /app/src ] && [ ! -L /app/src ]; then cp -r /app/src "$W/src/src"; fi
find "$W/src/crates"/*/src "$W/src/src" -type l -delete 2>/dev/null
chown -R 10003:10003 "$W"

{
  for crate in /opt/base-src/crates/*/; do
    name=$(basename "$crate")
    [ "$name" = nu-test-support ] && continue
    diff -ruN "/opt/base-src/crates/$name/src" "$W/src/crates/$name/src"
  done
  diff -ruN /opt/base-src/src "$W/src/src"
} 2>/dev/null | sed -e "s#/opt/base-src/#a/#g" -e "s#$W/src/#b/#g" | head -c 600000 >"$LOGS/submission.diff"

run_stage build 1800 bash /grading/stage_build.sh
run_stage frame 1200 bash /grading/stage_frame.sh
run_stage plugin 600 bash /grading/stage_plugin.sh

# R6 and R9: each authored case is its own nu process over the built nu and example plugin, with a
# root-run local HTTP server for the http cases. A case's `def` and `@` attribute lines are hoisted
# out of the try block, in their order.
python3 /grading/serve.py 18731 >/dev/null 2>&1 &
server=$!
sleep 1
bin=$W/src/target/debug
for case in /grading/cases/*.nu; do
  id=$(basename "$case" .nu)
  defs=$(grep -E '^(def |@)' "$case")
  body=$(grep -v -E '^(def |@)' "$case")
  install -d -o 10003 -g 10003 -m 0755 "$W/case-$id"
  code="$defs
try { $body } catch {|e| {error: \$e.msg} } | to nuon"
  run_stage "cases/$id" 120 bash -c 'cd "$1" && exec "$2/nu" --no-config-file --no-std-lib --plugins "[$2/nu_plugin_example]" -c "$3"' \
    case "$W/case-$id" "$bin" "$code"
done
kill "$server" 2>/dev/null
wait "$server" 2>/dev/null

for f in build.err frame.out plugin.err; do
  tail -c 300000 "$R/$f" >"$LOGS/$f.log" 2>/dev/null
done

python3 /grading/summarize.py --raw "$R" --grading /grading --logs "$LOGS" \
  --survivors "$survivors" --elapsed "$(( $(date +%s) - start ))"
