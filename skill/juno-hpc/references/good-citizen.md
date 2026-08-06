# Good-Citizen Policy — how this account never looks aggressive

Design axiom: **fairshare is the only currency.** Juno priority = `100,000×FairShare + 1,000×JobAge + 1,000×JobSize`. Fairshare is **group-level**, decays with use, recovers over ~2 weeks, resets to 1.0 on the 1st of each month. A 0.01 fairshare drop erases the entire 14-day age credit — so "submit early and let it age" is never a strategy, and inflating a request to gain size points costs ~100× more than it earns. The winning (and polite) strategy is always: right-size, pack, throttle.

## 1. Self-imposed caps (stricter than system limits)

| Dimension | System limit | Skill default | Needs explicit user approval |
|---|---|---|---|
| Running jobs | 4 | **2** | 3–4 |
| Pending jobs | 100 submitted | **10** | up to 25 |
| Nodes per job | 8 | **1** | 2+ (must articulate the MPI story) |
| Cores per job | 64/node (128 on a30 nodes) | **≤16** unless measured | full node |
| GPUs per job | 4 (h100) | **1** | 2+ |
| Jobs per burst | — | **≤5 per 60s** (absolute; the tool refuses more — pack into a launcher job) | — |

Mechanically enforced by `juno.sh submit` (exit 60): the caps (2/10, reduced to 1/5 in YELLOW), the burst limit (≤5 submits/60s), the dev smoke-test gate, explicit `--mem`/`--time`, GPU jobs require `--gpus`, and the fairshare bands below. Overrides (`--override-caps` ceilinged at the system limits, `--override-fairshare`, `--skip-dev-gate`) exist but require the user's explicit approval in the current session.

## 2. Batch work: pack, don't spray

N similar small tasks:
- N ≤ 4 → individual jobs.
- 5 ≤ N ≤ 50 → **one `launcher` job** (class `launcher`; tasklist file, `LAUNCHER_PPN` sized so tasks×threads ≤ 64). One queue entry instead of N; also the *fastest* option given the 4-running-job system cap — politeness and throughput coincide here.
- N > 50 → sequential launcher jobs of ≤50 tasks.
- **SLURM arrays are not supported by this tool** (`submit` refuses them, no override): `squeue` compresses pending array elements so the job caps would under-count them, and array element IDs (`<jobid>_<task>`) don't match the numeric `$SLURM_JOB_ID` scratch naming that `clean-scratch` depends on. Use launcher packing. If an array is genuinely unavoidable, the user submits and manages it manually.
- A 56-fit multiverse = ONE job parallelizing over the spec grid via `parallel::mclapply`/launcher, never 56 submissions.

## 3. Resource right-sizing

**`--mem` is always explicit** — per the orientation, an unspecified `--mem` defaults to 64 GB (exact SLURM semantics unverified — all the more reason never to rely on it). Over-allocation is the single biggest silent fairshare leak; `juno.sh gen`/`submit` hard-fail without it.

| Workload | cores | mem | notes |
|---|---|---|---|
| R / data.table | 8–16 | 2.5× on-disk data, min 8G | `setDTthreads()` from `$SLURM_CPUS_PER_TASK` |
| R / mgcv bam | 4–8 | 4× data | `discrete=TRUE`, `nthreads=` request |
| R / brms | 4 (=chains); more only w/ `threads_per_chain` | 8–16G | `cores = chains × threads_per_chain` |
| Python | 4–8 | 2× working set | BLAS env vars pinned to request |
| Stata | min(MP license cores, 8) | 1.5× dataset | probe license cores once on dev |
| GPU | 8–16 CPU per GPU | 32–64G | VRAM ≤6G→`a30-4.6gb`, ≤12G→`a30-2.12gb`, ≤24G→`a30`, >24G→`h200` before `h100` (only 3 h100 nodes — scarce) |

**Time:** `--time = ceil(1.5 × best estimate) + 15 min`, never the partition max as padding. If a job finishes under 25% of its request twice, halve the next request. After every job, `juno.sh post <id>` records MaxRSS/Elapsed and prints `SUGGEST_MEM` — **use it to seed the next submission**.

**Smoke-test gate** (mechanically enforced). `gen` computes a **payload digest** over every file that would be staged from `code/` (path + mode + content) and stamps it into the job file along with a hash of the wrapper body; `submit` recomputes both and refuses on any mismatch. A production submit requires a COMPLETED row in `.juno/usage.tsv` carrying **that same payload digest** — so the gate proves *this* code was tested, not merely that some job reused a name. Changing any staged file (entry point *or* helper) requires a fresh smoke test. `submit` also uploads an immutable per-digest code snapshot that the job copies from, so a later `push` can't change what an already-queued job runs. Workflow: run the test on 1–5% subsampled data (brms: `iter=200`) with `submit --smoke`, then `juno.sh post <id>` records the row that opens the gate.

`--smoke` must be claimed explicitly and the job must fit the envelope: a smoke partition (`dev`, `a30-4.6gb`, `a30-2.12gb`) **and** ≤30 min, ≤8 cores, ≤32 GB, ≤1 GPU. Smoke jobs skip the gate and the fairshare RED/unreadable-`sshare` refusals (they cost ~1 core-hour); everything else does not.
- **CPU work:** `--partition dev --time 00:15:00 --cpus 4 --mem 8G`.
- **GPU work:** `dev` has no GPUs, so smoke-test on the smallest fractional-GPU partition instead — `--partition a30-4.6gb --gpus 1 --time 00:15:00 --cpus 4 --mem 8G` (a completed run on `a30-4.6gb` or `a30-2.12gb` opens the gate for `a30`/`h100`/`h200`) — and gives you MaxRSS/Elapsed to size production (`mem = MaxRSS_scaled × 1.5`). Always dev-test regardless of history when requesting >12h, >32 cores, >128G, or first GPU use of a script. A dev test costs ~1 core-hour — a mis-sized 48h×64-core failure costs 3,072. `--skip-dev-gate` only with the user's explicit approval.

## 4. Fairshare throttle (checked by `juno.sh budget` / `submit`)

| FairShare | Mode | Behavior |
|---|---|---|
| ≥ 0.75 | GREEN | defaults apply |
| 0.50–0.75 | YELLOW | proceed; drop to 1 running / 5 pending; tell the user the number |
| 0.25–0.50 | ORANGE | auto-submit only small jobs (≤8 cores, ≤4h, ≤32G); bigger asks the user first |
| < 0.25 | RED | `submit` refuses (exit 60) without `--override-fairshare` + explicit user approval; smoke-envelope jobs submitted with `--smoke` remain allowed. The same exemption applies when `sshare` cannot be read at all (which otherwise fails closed). |

- Fairshare is shared with the whole group — check every session; a labmate's campaign can put you in ORANGE overnight. Alert the user on a drop >0.15 between sessions.
- Campaigns >~2,000 core-hours: surface the month-end option (debt is wiped at the monthly reset) — inform, never delay without asking.

## 5. Polling etiquette

- All polling runs **on the Mac** (`juno.sh wait`), one multiplexed SSH exec per poll. Never `watch`, `while` loops, cron, tmux/screen daemons on the login node.
- Floor **60 s** (enforced), default 120 s; scale to the job: interval ≈ `clamp(requested_time/10, 60 s, 30 min)`.
- Hard ceilings: ≤1 poll/min sustained (the enforced floor), so ≤60 SSH execs/hour from polling; reserve the 60 s floor for short jobs and let the 120 s default (or `requested_time/10`) handle long ones. One `juno.sh` command at a time — no parallel fan-out of waits.
- No polling when nothing is queued or running.
- Claude-side: run `juno.sh wait` as a background Bash task; do NOT wrap `juno.sh status` in an agent loop.

## 6. Login-node etiquette

Allowed: `sbatch squeue sacct scancel sinfo sshare sprio`, `module avail/list/spider`, `mfsgetquota`, file edits, `git`, bounded `ls/du -s/cp/mv`, rsync/scp, `<binary> --version`.
Not allowed: executing R/Python/Stata/Julia workloads, `mpirun` (doesn't work there anyway), real compilation, heavy `conda create`/solves, `pip install` of source builds (→ dev job), tarring >5 GB, anything that listens on a port.

## 7. Storage hygiene

- Jobs never touch `$HOME` (50 GB / 300k inodes). Conda envs, R libraries → `~/work` (inode bombs kill home first).
- Scratch discipline is enforced in every template: per-job dir `~/scratch/<slug>-<jobid>`; a `trap cleanup EXIT` copies results out and removes scratch on normal exit and on most failures/timeouts (scratch is preserved, not deleted, if the copy-out itself fails). The trap **cannot** fire on node failure or a hard kill — that's what `juno.sh clean-scratch` sweeps. Scratch is a buffer, never a store (45-day purge; never the only copy).
- Quota preflight before pushes (`mfsgetquota`); warn ≥80%, abort ≥90%.
- Weekly-ish: `juno.sh clean-scratch --yes` sweeps own orphaned scratch dirs (with user confirmation).

## 8. Red lines — DO NEVER

1. Never run computation/compilation/env-building on login nodes.
2. Never start persistent services (ollama serve, Jupyter left running, web servers, DBs). Batch inference inside a job, then exit.
3. Never evade limits (second accounts, labmates' NetIDs). Limit-relaxation requests go as a *draft email* to circ-assist@utdallas.edu that the user sends personally.
4. Never submit >5 jobs per minute (the tool refuses; pack into a launcher job — there is no burst override).
5. Never poll faster than 60 s or leave loops/daemons on login nodes.
6. Never request multi-node or multi-GPU allocations without explicit per-job user sign-off (`--override-caps`). `--exclusive` and job arrays aren't in the tool's directive allowlist at all — if either is truly needed, the user submits that job manually.
7. Never omit `--mem`; never pad `--time` to the partition max.
8. Never auto-resubmit a failed job more than once, and only after `sacct` diagnosis with a *changed* request. Crash-loop resubmission is the classic aggressive-account signature. Genuine code bugs get fixed and re-tested locally/dev first.
9. Never `touch` scratch files to defeat the purge.
10. Never write job I/O to `$HOME`; never leave scratch dirs behind.
11. Never submit in RED fairshare without explicit per-job user approval.
12. Never store the NetID password anywhere (no sshpass/expect/keychain-fed automation); never bypass VPN/security controls; never auto-accept a changed host key.
