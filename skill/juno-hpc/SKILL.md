---
name: juno-hpc
description: Submit, monitor, and retrieve computational jobs on UTD's Juno HPC cluster (SLURM) over SSH — automatically but politely, so the account never looks aggressive. Triggers on "run this on Juno", "offload to HPC", "run the robustness battery on Juno", "UTD cluster", or when an analysis is too heavy for the laptop (long brms/bam fits, big bootstraps, GPU work). UTD Juno ONLY — not for other clusters (e.g., UM Great Lakes has its own greatlakes-job-generator agent). Not for rendering tables/plots or interactive model development (run those locally).
---

# juno-hpc — UTD Juno Cluster Automation

> **Version 1.0 | 2026-08-05** · Ground truth: `references/juno-facts.md` (from Juno Orientation v14). When live cluster output disagrees with any reference file, trust the live system and propose a fact-sheet patch.

Lets Claude Code (or Codex, via `AGENTS.md`) run computational work on Juno end-to-end: preflight → job spec → generate → sync → submit → monitor → fetch → log. All mechanics live in `scripts/juno.sh` (one CLI, machine-parseable `KEY=value` stdout); the agent supplies judgment (resource sizing, diagnosis, user communication).

## Core principles

### P1 — The agent never touches the NetID password
All scripted SSH uses `BatchMode=yes` and *cannot* hang on a prompt. Interactive auth (`juno.sh setup <netid>`, `juno.sh connect`) is run by the **user in their own terminal** (suggest `! scripts/juno.sh setup <netid>` / `! scripts/juno.sh connect`); the ControlMaster socket then carries ~8h of scripted calls. Never sshpass/expect/stored passwords; never auto-accept a changed host key.

### P1b — Only through juno.sh
Interact with Juno **only** via `juno.sh` subcommands — never raw `ssh juno <command>`, never parallel `juno.sh` invocations (one command at a time; multiplexed SSH means one connection to a shared login node). If a guard blocks you and no override applies, that is the user's decision point, not a reason to go around the tool.

### P2 — Fairshare before throughput
Read `references/good-citizen.md` before any submission session. Fairshare is group-level and 100×-weighted; the skill's self-imposed caps (2 running / 10 pending), explicit `--mem`+`--time`, dev smoke-test gate, launcher-packing, and the GREEN/YELLOW/ORANGE/RED throttle are hard policy, not suggestions. `juno.sh submit` enforces the mechanical parts (exit 60 = policy guard).

### P3 — Execution backend, never author
In cowrite projects, juno-hpc runs code that already passed the empirical-helper A6 gate; it never writes or edits analysis scripts and never touches `drafts/`. See `references/cowrite-integration.md` for the full contract (byte-identical result paths, replication capture, logging, the IRB data-clearance hard block, and the mandatory HPC@UTD acknowledgment).

### P4 — No autonomous escalation
Never auto-resubmit a failed job (one diagnosed, changed-request retry max — with user approval). Never exceed a cap with `--override-*` flags without the user's explicit words this session. On VPN-down (exit 11) or auth-needed (exit 10), ask the user and stop — no retry loops.

## Workflow

**P0 · Preflight.** `scripts/juno.sh doctor` — connectivity, auth, remote dirs, quota. Exit 11 → user must connect the UTD VPN; exit 10 → user runs `ssh juno true` (or `juno.sh connect`). First time ever: user runs `juno.sh setup <netid>` (lowercase NetID), then run the verify-on-first-connect checklist in `references/software-recipes.md` and cache findings to `references/juno-live.md`.

**P1 · Job spec.** Read the target script + data sizes. Decide workload class (r | python | stata | gpu | launcher | cpu), partition, cores, mem, time per the sizing tables in `references/good-citizen.md` §3 — seed from `.juno/usage.tsv` history when the script ran before. Check `juno.sh budget` (ADVICE=ok|reduce|throttle|pause; report a `FS_DROP` > 0.15 to the user — a group-mate is burning fairshare). **Smoke-test gate (enforced by payload digest): every code version must pass a short test on subsampled data before production.** Run it with `juno.sh submit <file> --smoke`, then `juno.sh post <id>`. CPU work tests on `--partition dev` (00:15:00, 4 cpus, 8G); **GPU work tests on `--partition a30-4.6gb --gpus 1`** (dev has no GPUs). The digest covers every staged file under `code/`, so editing the entry point *or any helper* invalidates the gate and needs a fresh smoke test. Also smoke-test anything >12h/>32c/>128G even if the gate would pass. State the spec to the user in one line before generating; for expensive jobs (>12h, >32 cores, GPU, >128G) get explicit approval.

**P2 · Generate.** `juno.sh gen --class r --name <slug> --script code/<file> --partition normal --cpus 8 --mem 16G --time 02:00:00 [--gpus N] [--args "..."]` → `.juno/jobs/<name>.sbatch`. The entry point must live under `code/` and exist locally (only `code/` and `data/` are synced); for `--class launcher`, `--script` is the tasklist file, e.g. `code/tasklist.txt`. Review the rendered script (modules, threads, scratch discipline are templated in — check they fit this workload).

**P3 · Sync.** `juno.sh push` (mirrors `code/` only — `drafts/`, `docs/`, `logs/`, `results/` are siblings of `code/` and are never part of any sync source) and, when inputs changed, `juno.sh push-data data/processed` (append-only; >10 GB requires user confirmation). **Data-clearance gate first**: IRB/restricted data never leaves the laptop without explicit per-dataset user consent (`references/cowrite-integration.md`).

**P4 · Submit.** `juno.sh submit .juno/jobs/<name>.sbatch` — guards run automatically (mem/time present, burst ≤5/min, dev gate, job caps 2 running/10 pending — 1/5 in YELLOW — and fairshare bands). Never more than 5 submits in a burst; 5–50 similar tasks means ONE launcher-class job, not a spray. Exit 60 → read `JUNO_ERR`: `guard_*` needs the user's explicit approval before any `--override-*`/`--skip-*` flag; `mem_required`/`time_required`/`gpus_required` just means fix the invocation. Parse `JOBID=`.

**P5 · Monitor.** `juno.sh wait <jobid> --poll <sec>` as a **background Bash task** (poll ≈ requested-time/10, floor 60s, cap 30min). Never wrap `juno.sh status` in your own loop. **Multiple live jobs: ONE `wait` on the longest job, then a single `status` sweep for the rest — never concurrent waits.** For multi-hour jobs, tell the user you'll report when it finishes and do other work. `wait` survives VPN blips (10 consecutive failures before giving up; the job keeps running — just re-run `wait`).

**P6 · Fetch + post-mortem.** On COMPLETED: `juno.sh post <jobid>` (records MaxRSS/Elapsed → `SUGGEST_MEM` for next time) then `juno.sh fetch` (results land at the same relative paths as a local run). On FAILED/TIMEOUT/OOM: `wait` auto-tails the log; diagnose — OOM → raise mem to `SUGGEST_MEM`-informed value; TIMEOUT → raise time or checkpoint; nonzero exit → fix code locally/dev first. One approved resubmit max.

**P7 · Log.** Cowrite projects: detailed entry in `logs/WORKLOG.md`, one line in `logs/COWORK_LOG.md`, gate-ledger `HPC` row, todo for the HPC@UTD acknowledgment (formats in `references/cowrite-integration.md`). Non-cowrite projects: append to the project's worklog. Report to the user: state, runtime, utilization, where results landed, fairshare after.

## Failure quick-reference (exit codes)

| Exit | Meaning | Correct reaction |
|---|---|---|
| 0 | ok | continue |
| 2 | usage error | fix the invocation |
| 10 | auth needed | user runs `ssh juno true` / `juno.sh connect`; stop |
| 11 | network/VPN | user connects UTD VPN; stop; one retry after confirmation |
| 12 | ssh/conn failed (other) | show `JUNO_HINT` to user |
| 13 | host key changed | **hard stop**, alert user, never auto-accept |
| 20 | local state / not set up | run `juno.sh init`, or user runs `setup <netid>` |
| 30 | remote command or rsync failed | read hint, report; rsync re-runs resume |
| 40 | job failed (from `wait`) | diagnose from auto-tailed log; no blind resubmit |
| 41 | `wait` gave up with no state | either conn lost (job still running → reconnect, re-run `wait`) or the job never existed; run `status <jobid>` to tell which |
| 50 | quota | `juno.sh du`, clean up remote storage, then push |
| 60 | policy guard | read `JUNO_ERR`: `guard_*` → user approval required; `*_required` → fix invocation; `confirm_needed`/`data_clearance` → ask the user, then re-run with the stated flag |
| other | unexpected | report the output verbatim to the user |

## Files

- `scripts/juno.sh` — the CLI (all subcommands: `juno.sh help`)
- `references/juno-facts.md` — cluster ground truth (partitions, storage, limits, fairshare math)
- `references/good-citizen.md` — caps, sizing tables, throttle, polling rules, red lines
- `references/software-recipes.md` — R/renv, conda, Stata, CUDA, launcher, first-connect checklist
- `references/cowrite-integration.md` — academic-cowriter contract, IRB gate, logging, acknowledgment
- `templates/job.*.sbatch.tmpl` — job script templates (scratch discipline + replication capture built in)
