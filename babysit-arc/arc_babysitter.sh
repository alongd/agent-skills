#!/usr/bin/env bash
# ARC Babysitter Supervisor — stateless poll loop (bundled with the babysit-arc skill).
#
# The mother process for an unattended campaign. Each iteration runs ONE headless Claude Code
# babysitting pass, then sleeps. The agent gets a FRESH context every pass, so context never grows —
# no /compact or handoff is ever needed. Durable job state lives entirely in the per-project
# STATUS.md / ISSUES.md / REPORT.md files; this script holds none.
#
# SINGLE orchestrator: enforced by a PID lockfile. Do not run a second copy, and do not also drive
# Claude interactively on these campaigns while it runs (it would double-book the zeus account).
#
# Lifecycle: runs passes on a loop; EXITS when the pool is DONE; on PAUSED it stays resident, slow-
# polling the state file (it does NOT exit on a blocker). To resume after fixing a blocker:
#     echo RUNNING > ~/Projects/.arc_babysitter.state
#
# Launch options:
#   - Reboot-resilient (recommended): the bundled systemd user unit `arc-babysitter.service`
#       systemctl --user enable --now arc-babysitter      # needs: loginctl enable-linger alon
#   - Manual tmux (does NOT auto-restart after a reboot; relaunch the same line):
#       tmux new -s arc 'bash ~/.claude/skills/babysit-arc/arc_babysitter.sh'
#       detach: Ctrl-b d   ·   reattach: tmux attach -t arc   ·   watch: tail -f ~/Projects/arc_babysitter.log
#
# Override defaults via env: ARC_SPEC, ARC_STATE_FILE, ARC_LOG, ARC_LOCK, ARC_BABYSITTER_INTERVAL (sec),
# ARC_BABYSITTER_PAUSE_POLL (sec), ARC_BABYSITTER_PASS_TIMEOUT.

set -uo pipefail

SPEC="${ARC_SPEC:-$HOME/Projects/ARC_CAMPAIGNS.md}"
STATE_FILE="${ARC_STATE_FILE:-$HOME/Projects/.arc_babysitter.state}"
LOG="${ARC_LOG:-$HOME/Projects/arc_babysitter.log}"
LOCK="${ARC_LOCK:-$HOME/Projects/.arc_babysitter.lock}"
INTERVAL="${ARC_BABYSITTER_INTERVAL:-1800}"        # seconds between passes (default 30 min)
PAUSE_POLL="${ARC_BABYSITTER_PAUSE_POLL:-600}"     # seconds between state-file checks while PAUSED
PASS_TIMEOUT="${ARC_BABYSITTER_PASS_TIMEOUT:-30m}" # max wall time for one pass

# --- single-orchestrator lockfile (ban insurance: never double-book the zeus account) ---
if [ -e "$LOCK" ]; then
  oldpid="$(cat "$LOCK" 2>/dev/null || true)"
  if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "$(date '+%F %T') another supervisor is alive (PID $oldpid) — refusing to start." >> "$LOG"
    exit 3
  fi
  echo "$(date '+%F %T') stale lockfile (PID ${oldpid:-?} dead) — reclaiming." >> "$LOG"
fi
echo $$ > "$LOCK"
cleanup() { rm -f "$LOCK"; echo "$(date '+%F %T') supervisor exit — lock released." >> "$LOG"; }
trap cleanup EXIT INT TERM

PASS_PROMPT="Use the babysit-arc skill. Read $SPEC, then do EXACTLY ONE babysitting pass of the ARC \
campaigns and STOP (end the session) — do not stay resident or sleep; this external supervisor \
handles cadence. First pass after a (re)boot: run the idempotent shared pre-flight. Each pass: check \
the zeus gate; advance the pool (validate each input.yml by loading an ARC object — \
ARC(**read_yaml_file(path,project_directory)) WITHOUT execute() — before launching any instance incl. \
new deviation sibling folders; launch queued instances up to the batch budget, BOUNDED by the zeus \
SSH budget — ~2-3 concurrent ARC processes max, not just by host RAM/CPU; health-check running ones \
incl. STALLED-but-alive instances (live PID but no arc.log/restart.yml advance for >~3h -> kill+restart \
within the retry budget, then mark blocked); restart crashed within the retry budget; run the \
elementary_high_p post-processing and per-project library consolidation for any project that just \
finished). FREELY APPLY local bug fixes to the ARC/RMG checkout to unblock the pool but NEVER commit \
them — log each in the project FIXES.md (timestamp, symptom, root cause, files, diff pointer). Keep \
STATUS.md (live ledger, timestamped heartbeat), each project's ISSUES.md (human follow-up: unconverged \
species, TSs not found, crashed/blocked, questionable results), and each project's REPORT.md (the \
single clean human deliverable: wins, didn't-converge+why+recommendation, code fixes applied with a \
git diff --stat snapshot, deviations, next actions) current. Be GENTLE with zeus SSH (account-ban \
risk): batch ALL per-pass zeus checks into ONE connection — ssh zeus 'qstat -u \$USER; quota -s' — one \
qstat for all jobs, never tight-loop on SSH failures, per the SSH budget in the vault (Running ARC On \
Zeus section 0b). GUARD the zeus home quota every pass from that batched 'quota -s': over soft -> warn \
+ lower max_simultaneous_jobs/hold launches; near hard -> hold launches and slack-notify (a pool-wide \
ENOSPC crash is a known killer). For multi-day runs, slack-notify a one-line liveness heartbeat at \
most once/24h (N processed / M running / K blocked). When the pass is finished, write EXACTLY ONE word \
to $STATE_FILE: DONE (every instance across the whole pool is terminal AND teardown is complete), \
PAUSED (a blocker needs the user — also slack-NOTIFY it, do NOT block on slack-ask, and record it in \
STATUS.md), or RUNNING (work continues). Write nothing else to that file."

echo "$(date '+%F %T') supervisor start (PID $$, interval=${INTERVAL}s, pause_poll=${PAUSE_POLL}s, timeout=${PASS_TIMEOUT})" >> "$LOG"
while true; do
  echo "$(date '+%F %T') --- pass start ---" >> "$LOG"
  timeout "$PASS_TIMEOUT" claude -p "$PASS_PROMPT" --dangerously-skip-permissions >> "$LOG" 2>&1
  rc=$?
  [ "$rc" -eq 124 ] && echo "$(date '+%F %T') pass TIMED OUT after ${PASS_TIMEOUT}" >> "$LOG"
  state="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || echo RUNNING)"
  echo "$(date '+%F %T') --- pass end (rc=$rc, state=${state:-RUNNING}) ---" >> "$LOG"
  case "$state" in
    DONE)
      echo "$(date '+%F %T') pool DONE — supervisor exiting." >> "$LOG"; exit 0 ;;
    PAUSED)
      # Stay resident: a blocker needs the user. Slow-poll the state file (run NO passes) until the
      # user resolves the cause and flips it back to RUNNING (echo RUNNING > $STATE_FILE).
      echo "$(date '+%F %T') PAUSED — a blocker needs the user. Resident; resolve, then 'echo RUNNING > $STATE_FILE'." >> "$LOG"
      while true; do
        sleep "$PAUSE_POLL"
        state="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || echo PAUSED)"
        case "$state" in
          RUNNING) echo "$(date '+%F %T') resumed by user (RUNNING) — running next pass." >> "$LOG"; break ;;
          DONE)    echo "$(date '+%F %T') marked DONE while paused — supervisor exiting." >> "$LOG"; exit 0 ;;
          *)       : ;;  # still PAUSED (or blank) — keep waiting, no Slack spam
        esac
      done
      ;;
    *)
      sleep "$INTERVAL" ;;
  esac
done
