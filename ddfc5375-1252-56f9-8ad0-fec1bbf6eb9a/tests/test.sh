#!/bin/bash
# Fail-closed verifier: grade as uid 20003, then run Reward Kit as uid 20002 if the gate is open.
set -uo pipefail
LOGS=/logs/verifier
# Grading time limit; past it the submission scores 0.
GRADE_BUDGET=1500
mkdir -p "$LOGS"
printf '0\n' >"$LOGS/reward.txt"

mirror_reward_txt() {
  python3 - "$LOGS/reward.json" "$LOGS/reward.txt" <<'PY'
import json, math, sys
try:
    value = float(json.load(open(sys.argv[1]))["reward"])
    if not math.isfinite(value) or not 0.0 <= value <= 1.0:
        raise ValueError(value)
except (OSError, ValueError, KeyError, TypeError):
    value = 0.0
open(sys.argv[2], "w").write(f"{value}\n")
PY
}
trap mirror_reward_txt EXIT

judge_env=()
judge_mode=none
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  judge_mode=anthropic
  judge_env+=("ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    judge_env+=("ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}" "ANTHROPIC_API_BASE=${ANTHROPIC_BASE_URL}")
  fi
  if [ -n "${REWARDKIT_JUDGE:-}" ]; then
    judge_env+=("REWARDKIT_JUDGE=${REWARDKIT_JUDGE}")
  fi
elif [ -n "${OPENAI_API_KEY:-}" ]; then
  judge_mode=openai
  judge_env+=("OPENAI_API_KEY=${OPENAI_API_KEY}" "REWARDKIT_JUDGE=${REWARDKIT_JUDGE:-openai/gpt-6.1-sol}")
  if [ -n "${OPENAI_BASE_URL:-}" ]; then
    judge_env+=("OPENAI_BASE_URL=${OPENAI_BASE_URL}" "OPENAI_API_BASE=${OPENAI_BASE_URL}")
  fi
fi

run_rewardkit() {
  timeout -s KILL 420 setpriv --reuid=20002 --regid=20002 --clear-groups \
    env -i PATH=/opt/rewardkit/bin:/usr/bin:/bin HOME=/home/verifier LANG=C.UTF-8 PYTHONNOUSERSITE=1 \
    "${judge_env[@]}" /opt/rewardkit/bin/rewardkit "$1"
}

judge_unavailable() {
  printf '%s\n' "$1" >"$LOGS/judge_unavailable"
  echo "judge_unavailable: $1" >&2
}

timeout -s KILL "$GRADE_BUDGET" bash /grading/grade.sh
rc=$?
# grade.sh empties the log directory before grading, so the fail-closed 0 is written again after it.
printf '0\n' >"$LOGS/reward.txt"
if [ "$rc" -eq 0 ]; then
  chown 20002:20002 "$LOGS"
  if [ "$judge_mode" != none ]; then
    for attempt in 1 2; do
      rm -f "$LOGS/reward.json"
      run_rewardkit /tests
      rk=$?
      if [ -s "$LOGS/reward.json" ]; then
        chown -R 0:0 "$LOGS"
        exit 0
      fi
      echo "Reward Kit with the $judge_mode judge exited $rk without a reward (attempt $attempt of 2)" >&2
      [ "$attempt" -lt 2 ] && sleep 30
    done
    judge_unavailable "the $judge_mode judge wrote no reward after 2 attempts; scoring the compiled items only"
  else
    judge_unavailable "no ANTHROPIC_API_KEY or OPENAI_API_KEY; scoring the compiled items only"
  fi
  judge_env=()
  compiled=$(mktemp -d)
  cp -a /tests/. "$compiled/"
  rm -f "$compiled/judge.toml"
  printf '[[reward]]\nname = "reward"\naggregation = "weighted-mean"\nweights = { test_output = 1 }\n\n[scoring.test_output]\naggregation = "weighted-mean"\n' >"$compiled/reward.toml"
  chmod -R a+rX "$compiled"
  rm -f "$LOGS/reward.json"
  run_rewardkit "$compiled"
  rk=$?
  chown -R 0:0 "$LOGS"
  if [ -s "$LOGS/reward.json" ]; then
    exit 0
  fi
  reason="compiled-only Reward Kit exited $rk without a reward"
elif [ "$rc" -eq 3 ]; then
  exit 0
else
  reason="grading exited $rc"
fi
printf '{"reward": 0.0}\n' >"$LOGS/reward.json"
printf '{"gate": {"open": false, "reason": "%s"}}\n' "$reason" >"$LOGS/reward-details.json"
exit 0
