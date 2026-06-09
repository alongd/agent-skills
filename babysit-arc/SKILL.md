---
name: babysit-arc
description: Autonomously run and babysit ARC (Automated Rate Calculator) campaigns on the OL workstation — generate run folders from a reaction/species spec, launch instances that submit QM jobs to the zeus PBS cluster, watch them, auto-fix known crashes and restart, and judge scientific correctness. Reaches the user over Slack only when it truly needs them (a real blocker or a confirmed scientific deviation) or when a campaign finishes. Use when asked to run/babysit an ARC campaign, run ARC on OL/zeus, compute k(T) or thermo for a set of reactions, or resume/monitor an ARC run.
---

# babysit-arc — run + babysit ARC campaigns on OL (with Slack)

This skill **executes the vault's ARC Campaign Runbook autonomously on OL** and adds a thin Slack
layer for high-signal human-in-the-loop. **The vault notes are the source of truth — read them; this
file only orchestrates and must not duplicate their depth.** Run it with one line, e.g. *"load
`~/Projects/ARC_CAMPAIGNS.md` and run it autonomously"*.

## Where it runs
**OL only** (`hostname Office`, on-network → reaches zeus directly, no VPN). ARC runs in **`arc_env`**;
RMG/Arkane in **`rmg_env`**. Heavy QM is on zeus (PBS); locally each instance is orchestration + Arkane.

## Step 0 — read the vault FIRST (authoritative)
Vault root on OL: `~/Dropbox/Apps/remotely-save/Vault/` (path per machine is in CC memory). Read:
- `knowledge/wiki/ARC Campaign Runbook.md` — the full process (autonomy rules, STATUS.md ledger,
  crash→fix→restart, success criteria, consolidation, teardown). **This governs everything below.**
- `knowledge/wiki/Running ARC On Zeus.md` — operational guide + failure modes.
- `Code/ARC/ARC on OL — Zeus Troubleshooting & Knowledge.md` — OL→zeus config, the **known-bug
  catalog**, validated `~/.arc/settings.py`/`submit.py`, queue policy.

Then read the run's state files: the launch file `~/Projects/ARC_CAMPAIGNS.md` and each campaign's
`RUN.md` (operating manual), `INDEX.md` (file map), and **`STATUS.md` — read this FIRST on any
(re)start; it is the resume ledger and single source of truth for what is running.**

## Autonomy contract
Run **without questions**, applying the documented defaults; **record every decision/anomaly/action as
a timestamped line in `STATUS.md`**, never halt for a choice the runbook already resolves. Reach the
user (Slack) **only** for the three cases in the Slack policy below. Never fabricate progress or grind
silently — on a true blocker, report honestly in `STATUS.md` and ask.

## Phase A — generation (spec → run folders)
Follow the runbook's Phase A: resolve species (SMILES; RMG adjacency lists for fragile aromatics/
radicals), confirm each reaction is an **elementary single-TS path** (`ARCReaction.determine_family()`)
and **prune only net / well-skipping** reactions (keep every elementary reaction, any molecularity),
partition into instances, write one `input.yml` per folder via the project's `gen_arc_inputs.py`, then
(re)generate `INDEX.md`/`STATUS.md` rows.

**Validate every `input.yml` against the ARC API before launch** (catches bad job-type keys, malformed
LOT, unresolved species early; runnable on **any** machine with ARC importable — even before copying to
OL). Construct the object, do **not** `execute()`:
```bash
conda run -n arc_env python -c "import sys,yaml; from arc import ARC; ARC(**yaml.safe_load(open(sys.argv[1]))); print('OK', sys.argv[1])" <instance>/input.yml
```
A failed load → fix the input; **never launch a broken instance.**

## Phase B — pre-flight (once per session)
Per the runbook + troubleshooting note (don't inline the configs here): correct **branches** on the
**main checkout** (not a worktree) and **recompile** if a branch switch touched Cython (`make-compile`
in `arc_env` / `make` in `rmg_env`); apply the **uncommitted** `arc/scheduler.py` server-poll edit
`time.sleep(30)`→`time.sleep(180)`; confirm **zeus is defined in `~/.arc/settings.py` and reachable**
(`ssh -o BatchMode=yes -o ConnectTimeout=15 alon@zeus.technion.ac.il 'echo ok'`); verify envs.

## Phase B — launch + babysitting loop (~30–60 min)
Launch one **detached** ARC process per instance from its dir (`setsid python ~/Code/ARC/ARC.py
input.yml &`), record PID+time in `STATUS.md`; **single orchestrator / one pool** across campaigns;
**autodetect** batch size from host (`nproc`, `free -g`) and the zeus queue (`qstat -u $USER` vs
`max_simultaneous_jobs`). Each pass, for every `running` instance check health (PID alive, `arc.log`
advancing, jobs cycling opt→freq→scan→sp, `restart.yml` updating, zeus jobs not stuck `Q`) and append
a **timestamped heartbeat** line to `STATUS.md`.

**Crash → fix → restart:** match the traceback to the vault **known-bug catalog** → fix in the host's
ARC/RMG checkout → restart from the instance dir (ARC resumes from `restart.yml`); bounded **retry
budget (3)**, then mark `blocked`/`crashed` and **continue with the others** (one bad instance never
stalls the pool).

- **Code fixes stay UNSTAGED — never `git add`/`git commit`.** Leave the edit in the working tree and
  record it in a **per-project `FIXES.md`**: bug, root cause, the diff/solution, files touched,
  timestamp. **Do not auto-edit the vault note** (Alon promotes confirmed learnings to the vault
  manually). Re-apply such uncommitted fixes after a fresh checkout.

## Success criteria — scientific correctness is the bar
Mark an instance `processed` only when the result exists **and** is scientifically sane (per the
runbook): rates → Arkane k(T); TS has exactly one imaginary freq of the right mode; IRC connects the
intended reactants↔products; rotors treated; SP at the intended high level. Thermo → NASA polynomials;
true minima; sane vs the estimate replaced. Never accept a converged-but-wrong number.

## Scientific diagnosis & input deviations (slack-ask before deviating)
Beyond pass/fail, **diagnose result quality and deep-think** about whether the LOT fits the goal.
Example: for a rate goal, a **TS T1 diagnostic > 0.02 at CCSD(T)** signals multireference character —
the single-reference LOT is suspect → recommend a higher-level method (e.g. **MRCI** or **HEAT**).
**Any** proposed departure from the original `input.yml` (LOT/basis/method) must be **diagnosed,
reasoned, and confirmed via `slack-ask`** before running — never changed silently.

**Deviation runs — folder convention:** restart in place for resume, but **never delete a run**. To
change an input, create a **new sibling subfolder** with a related name (`xt1001` → `xt1001b`, `…c`),
**comment in the new `input.yml` what changed and why** (header), keep the original intact for
diagnosis, and add an `INDEX.md`/`STATUS.md` row linking child→parent.

## Post-processing & teardown
Tag pressure-dependent (unimolecular) entries `elementary_high_p=True` via the project's
`add_elementary_high_p.py` before consolidating. When all instances of a project are done, merge their
per-instance RMG libraries into one project library reusing **T3**'s
`t3/utils/libraries.py` (`append_to_rmg_library` / `append_to_rmg_libraries`). When the **whole pool**
is terminal, **revert** the uncommitted `scheduler.py` poll edit (`git -C ~/Code/ARC checkout --
arc/scheduler.py`); re-apply on any restart/resume. **Resume after outage:** read `STATUS.md`,
re-launch every non-`processed` instance, re-run pre-flight.

## Slack policy — minimal, high-signal (every message means "needs me")
Invoke the existing **`slack-ask`** / **`slack-notify`** skills (they post as the bot via
`/home/alon/.claude/bin/cc-slack-post.py` to `#cc-comm`). Send Slack **only** in these cases:
1. **Real blocker → `slack-ask`** (pause + wait): can't reach zeus, broken `~/.arc/settings.py`/
   branches, a failure surviving the fix→restart budget, an ambiguous result you can't safely accept or
   reject, or any infra loss that stalls the run. Record it in `STATUS.md` first, then ask; resume per
   the reply.
2. **Scientific deviation → `slack-ask`** (confirm first): a diagnosed LOT/method change or any
   departure from the original input. Present diagnosis + recommendation; on approval, spawn the new
   sibling-folder run keeping the original.
3. **Campaign finished → `slack-notify`** (one summary): `processed`/`blocked` counts + where the
   consolidated libraries are. With a shared pool, notify when the whole pool is terminal.

**Otherwise: no Slack.** Normal progress, routine auto-fixes, and per-pass heartbeats go to `STATUS.md`
only — do not spam the channel.

## Related
Vault: `[[ARC Campaign Runbook]]` · `[[Running ARC On Zeus]]` · `ARC on OL — Zeus Troubleshooting`.
Slack: `slack-ask`, `slack-notify`.
