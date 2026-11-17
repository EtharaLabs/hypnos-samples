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
# Make the log directory root-only before any agent code runs.
mkdir -p "$LOGS"
chown 0:0 "$LOGS"
chmod 0755 "$LOGS"
find "$LOGS" -mindepth 1 -maxdepth 1 ! -name test-stdout.txt -exec rm -rf {} +
rm -rf "$G" /tmp/tester-home
install -d -m 0755 "$G"
install -d -m 0700 "$R" "$R/run"
install -d -o 20003 -g 20003 -m 0755 "$W" /tmp/tester-home
start=$(date +%s)
survivors=0
TOOLBIN=$(dirname "$(cd /opt/base-src && rustup which cargo)")
GRADED="crates/swc_ecma_transforms_typescript/src crates/swc_ecma_transforms_base/src crates/swc_ecma_utils/src crates/swc_atoms/src"

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
    env -i PATH="$TOOLBIN:/opt/swc-exec-tools/node_modules/.bin:/usr/bin:/bin" HOME=/tmp/tester-home \
    LANG=C.UTF-8 NODE_PATH=/opt/swc-exec-tools/node_modules CARGO_HOME=/usr/local/cargo \
    CARGO_NET_OFFLINE=true "$@" >"$R/$name.out" 2>"$R/$name.err"
  echo $? >"$R/$name.rc"
  reap
}

# Graded tree: pristine base and hidden tests, with the agent's graded sources copied over it.
cp -a /opt/base-src "$W/src"
for dir in $GRADED; do
  rm -rf "${W:?}/src/$dir"
  if [ -d "/app/$dir" ] && [ ! -L "/app/$dir" ]; then cp -r "/app/$dir" "$W/src/$dir"; fi
done
for dir in $GRADED; do
  [ -d "$W/src/$dir" ] && find "$W/src/$dir" -type l -delete
done
# The tree is root-owned: the test phase can write only its build directory and /tmp.
chown -R 0:0 "$W/src"
chmod -R a+rX,go-w "$W/src"
install -d -o 20003 -g 20003 -m 0755 "$W/src/target"

{
  for dir in $GRADED; do
    diff -ruN "/opt/base-src/$dir" "$W/src/$dir"
  done
} 2>/dev/null | sed -e "s#/opt/base-src/#a/#g" -e "s#$W/src/#b/#g" | cap_diff >"$LOGS/submission.diff"

run_stage build 2400 bash /grading/stage_build.sh

# Each test executable the build stage reported runs once, from its package directory.
python3 /grading/summarize.py --raw "$R" --list "$W/src" >"$G/executables.tsv" 2>/dev/null
: >"$R/runs.tsv"
n=0
while IFS=$'\t' read -r exe dir; do
  case "$dir" in "$W/src"|"$W/src/"*) ;; *) continue ;; esac
  n=$((n + 1))
  stem=$(printf '%02d-%s' "$n" "$(basename "$exe")")
  printf '%s\t%s\n' "$stem" "$exe" >>"$R/runs.tsv"
  run_stage "run/$stem" 1200 bash /grading/stage_run.sh "$exe" "$dir"
done <"$G/executables.tsv"

tail -c 200000 "$R/build.err" >"$LOGS/build.err.log" 2>/dev/null
for f in "$R"/run/*.err; do
  [ -f "$f" ] && tail -c 50000 "$f" >"$LOGS/run-$(basename "$f").log"
done

python3 /grading/summarize.py --raw "$R" --grading /grading --logs "$LOGS" \
  --survivors "$survivors" --elapsed "$(( $(date +%s) - start ))"
