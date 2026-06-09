#!/usr/bin/env bash
# ARC Babysitter Supervisor — stateless poll loop (bundled with the babysit-arc skill).
#
# The mother process for an unattended campaign. Each iteration runs ONE headless Claude Code
# babysitting pass, then sleeps. The agent gets a FRESH context every pass, so context never grows —
# no /compact or handoff is ever needed. Durable job state lives entirely in the per-project
# STATUS.md / ISSUES.md files; this script holds none.
#
# SINGLE orchestrator: do not run a second copy, and do not also drive Claude interactively on these
# campaigns while it runs.
#
# Launch (manual, in tmux — does NOT auto-restart after a reboot; relaunch the same line):
#     tmux new -s arc 'bash ~/.claude/skills/babysit-arc/arc_babysitter.sh'
#     detach: Ctrl-b d   ·   reattach: tmux attach -t arc   ·   watch: tail -f ~/Projects/arc_babysitter.log
#
# Override defaults via env: ARC_SPEC, ARC_STATE_FILE, ARC_LOG, ARC_BABYSITTER_INTERVAL (sec),
# ARC_BABYSITTER_PASS_TIMEOUT.

set -uo pipefail

SPEC="${ARC_SPEC:-$HOME/Projects/ARC_CAMPAIGNS.md}"
STATE_FILE="${ARC_STATE_FILE:-$HOME/Projects/.arc_babysitter.state}"
LOG="${ARC_LOG:-$HOME/Projects/arc_babysitter.log}"
INTERVAL="${ARC_BABYSITTER_INTERVAL:-1800}"        # seconds between passes (default 30 min)
PASS_TIMEOUT="${ARC_BABYSITTER_PASS_TIMEOUT:-30m}" # max wall time for one pass

PASS_PROMPT="Use the babysit-arc skill. Read $SPEC, then do EXACTLY ONE babysitting pass of the ARC \
campaigns and STOP (end the session) — do not stay resident or sleep; this external supervisor \
handles cadence. First pass after a (re)boot: run the idempotent shared pre-flight. Each pass: check \
the zeus gate; advance the pool (launch queued instances up to the batch budget, health-check running \
ones, restart crashed within the retry budget, run the elementary_high_p post-processing and \
per-project library consolidation for any project that just finished); keep both STATUS.md (live \
ledger, timestamped heartbeat) and each project's ISSUES.md (human follow-up: unconverged species, \
TSs not found, crashed/blocked, questionable results) current. When the pass is finished, write \
EXACTLY ONE word to $STATE_FILE: DONE (every instance across the whole pool is terminal AND teardown \
is complete), PAUSED (a blocker needs the user — also slack-ask and record it in STATUS.md), or \
RUNNING (work continues). Write nothing else to that file."

echo "$(date '+%F %T') supervisor start (interval=${INTERVAL}s, timeout=${PASS_TIMEOUT})" >> "$LOG"
while true; do
  echo "$(date '+%F %T') --- pass start ---" >> "$LOG"
  timeout "$PASS_TIMEOUT" claude -p "$PASS_PROMPT" --dangerously-skip-permissions >> "$LOG" 2>&1
  rc=$?
  [ "$rc" -eq 124 ] && echo "$(date '+%F %T') pass TIMED OUT after ${PASS_TIMEOUT}" >> "$LOG"
  state="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || echo RUNNING)"
  echo "$(date '+%F %T') --- pass end (rc=$rc, state=${state:-RUNNING}) ---" >> "$LOG"
  case "$state" in
    DONE)   echo "$(date '+%F %T') pool DONE — supervisor exiting." >> "$LOG"; exit 0 ;;
    PAUSED) echo "$(date '+%F %T') PAUSED — a blocker needs the user. Supervisor stopping; resolve, then relaunch." >> "$LOG"; exit 2 ;;
    *)      sleep "$INTERVAL" ;;
  esac
done
