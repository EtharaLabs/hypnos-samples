#!/bin/bash
# Verifier entry. Starts as root only to drop privileges: every stage that compiles or runs the
# agent's code runs as uid 10003 without the judge key, and Reward Kit runs as uid 10002 with it,
# only after every uid 10003 process is gone and only when the reward gate is open. A closed gate, a
# grading failure, or a Reward Kit run that writes no reward all leave reward.json at 0.0.
set -uo pipefail
LOGS=/logs/verifier
bash /grading/grade.sh
rc=$?
if [ "$rc" -eq 0 ]; then
  chown 10002:10002 "$LOGS"
  setpriv --reuid=10002 --regid=10002 --clear-groups \
    env -i PATH=/opt/rewardkit/bin:/usr/bin:/bin HOME=/home/verifier LANG=C.UTF-8 \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    /opt/rewardkit/bin/rewardkit /tests
  rk=$?
  if [ -s "$LOGS/reward.json" ]; then
    exit 0
  fi
  reason="reward kit exited $rk without a reward"
elif [ "$rc" -eq 3 ]; then
  exit 0
else
  reason="grading exited $rc"
fi
printf '{"reward": 0.0}\n' >"$LOGS/reward.json"
printf '{"gate": {"open": false, "reason": "%s"}}\n' "$reason" >"$LOGS/reward-details.json"
exit 0
