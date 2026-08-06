# AGENTS.md — juno-hpc for Codex and other CLI agents

Operate UTD's Juno HPC cluster via `scripts/juno.sh` only. Full playbook: `SKILL.md`; policy: `references/good-citizen.md`; cluster facts: `references/juno-facts.md`. This file is the operational digest.

## Rules (non-negotiable)

1. Only call `scripts/juno.sh` subcommands; never raw `ssh juno <compute command>`. One command at a time — no parallel fan-out; multiple live jobs = one `wait` on the longest, then a single `status` sweep.
2. Never handle the user's password. Exit 10 → tell the user to run `ssh juno true`; exit 11 → tell the user to connect the UTD VPN; exit 20/`not_setup` → user runs `juno.sh setup <netid>`. Stop and wait; one retry after the user confirms.
3. Every job needs explicit `--mem` and `--time`; GPU jobs need `--gpus` (`gen` refuses otherwise — Juno defaults to 64G if mem is unset, per orientation).
4. Respect exit 60 (policy guards: allowlisted `#SBATCH` directives only; caps 2 running/10 pending — 1/5 in YELLOW fairshare; burst ≤5/min; payload-digest smoke-test gate; fairshare ORANGE size limit 8c/4h/32G; RED refusal — smoke-envelope jobs submitted with `--smoke` are exempt from RED and from an unreadable `sshare`; data clearance). Read `JUNO_ERR`: `guard_*` → the user's explicit approval is required before `--override-caps` (ceiling 4/25), `--override-fairshare`, or `--skip-dev-gate`; `*_required` → fix the invocation; `confirm_needed`/`data_clearance` → ask the user, then re-run with the stated flag.
5. Never auto-resubmit a failed job. Diagnose (`wait` auto-tails the log; `juno.sh post` gives MaxRSS), propose a changed request, get approval. One retry max.
6. Poll only via `juno.sh wait` (floor 60s). Never loop `juno.sh status` yourself. Never run loops/daemons on the login node.
7. Batch of N similar tasks: N≤4 individual jobs; 5–50 one `launcher`-class job with a tasklist; >50 sequential launcher jobs. Never spray sbatch.
8. Every new/edited payload → smoke test first: `submit <file> --smoke` then `juno.sh post <id>`; production is refused until a COMPLETED row exists carrying that **payload digest** (a hash of every staged file under `code/`, stamped in by `gen`). Editing ANY staged file — entry point or helper — invalidates it and needs a fresh smoke test. CPU: `--partition dev --time 00:15:00 --cpus 4 --mem 8G`. GPU: `--partition a30-4.6gb --gpus 1 --time 00:15:00 --cpus 4 --mem 8G` (dev has no GPUs). `--script` must be a real file under `code/` (no symlinks, no spaces).
9. Cowrite projects: never modify analysis scripts or `drafts/`; results must land at local-identical relative paths; log per `references/cowrite-integration.md`; IRB/restricted data requires explicit user consent (`push-data` outside `data/processed` refuses without `--cleared-by-user`); remind about the HPC@UTD acknowledgment.
10. UTD Juno only. Other clusters (e.g., UM Great Lakes) have their own tooling.

## Command sequence (happy path)

```bash
S=<path-to-skill>/scripts/juno.sh
"$S" doctor                         # exit 11→VPN, 10→ssh juno true, 20→setup <netid>
"$S" init                          # once per project (from project root)
"$S" budget                        # ADVICE=ok|reduce|throttle|pause; watch FS_DROP
"$S" push                          # code mirror
"$S" push-data data/processed      # only when inputs changed; >10GB → ask user, add --yes
# first run of a code version: smoke test, then post (records the payload digest that opens the gate)
"$S" gen --class r --name m1-smoke --script code/05_model.R \
     --partition dev --cpus 4 --mem 8G --time 00:15:00
"$S" submit .juno/jobs/m1-smoke.sbatch --smoke && "$S" wait <id> --poll 60 && "$S" post <id>
# then production: the gate keys on the PAYLOAD DIGEST (all staged files under code/),
# not the job name, so any --name works as long as nothing under code/ changed since the smoke test
"$S" gen --class r --name m1 --script code/05_model.R \
     --partition normal --cpus 8 --mem 16G --time 02:00:00
"$S" submit .juno/jobs/m1.sbatch   # prints JOBID=<id>
"$S" wait <id> --poll 120          # run in background; exit 0=COMPLETED, 40=failed(log tailed)
"$S" post <id>                     # MaxRSS/Elapsed + SUGGEST_MEM (seed next run)
"$S" fetch                         # remote results/ -> local results/
```

Also available: `logs <jobid> [--tail N]` (tail the SLURM output file), `cancel <jobid>`, `du` (remote sizes + quota, use on exit 50), `clean-scratch --yes` (sweep own orphaned scratch dirs). Full list: `juno.sh help`.

## Output protocol

stdout = `KEY=value` lines, plus fenced free-text blocks (`---LOG BEGIN…---`/`---LOG END---` for `logs`, `---REPORT BEGIN <cmd>---`/`---REPORT END---` for `doctor`/`status`/`du`). Everything outside a fence is `KEY=value`. stderr = prose. Parse stdout only. Key keys: `JUNO_OK`, `JUNO_ERR`, `JUNO_HINT`, `JOBID`, `STATE`, `FAIRSHARE`, `ADVICE`, `SUGGEST_MEM`, `MAXRSS_MB_PER_TASK`, `NTASKS`, `RUNNING`, `PENDING`.

`SUGGEST_MEM=per-task-only` means the job had multiple tasks: `MAXRSS_MB_PER_TASK` is one task's peak, so size the next request from concurrent-task totals rather than scaling that number.

## Exit codes

0 ok · 2 usage · 10 auth needed (user: `ssh juno true`) · 11 no network/VPN · 12 ssh/conn other · 13 host key changed (HARD STOP) · 20 local state or not set up (`init` / user runs `setup`) · 30 remote or rsync failed (re-runs resume) · 40 job failed · 41 `wait` gave up with no state — EITHER connection lost (job still running: re-run `wait`) OR the job never existed/reached accounting; run `status <jobid>` to tell which · 50 quota (`juno.sh du`, clean up) · 60 policy guard (see rule 4) · other: report verbatim

## Sizing cheat (details: references/good-citizen.md §3)

R data.table 8–16c / 2.5×data; brms 4c (=chains) / 8–16G; mgcv bam 4–8c / 4×data; Python 4–8c / 2×working-set; Stata ≤ license cores; GPU by VRAM: ≤6G a30-4.6gb · ≤12G a30-2.12gb · ≤24G a30 · >24G h200 (h100 scarce). Time = 1.5× estimate + 15min, cap 48h. Partitions: dev 2h (tests) · normal 2d (production CPU) · GPU as above.
