# Software Recipes on Juno

Module names below are July-2026 snapshots; templates use `module load X/ver || module load X` fallbacks. Verify drift with `module -t avail <name>`.

## R (primary language)

**Module R + user library under `~/work`, renv for locking. Not conda-R** (duplicates the toolchain, bloats quotas, diverges from the OpenHPC gnu14 build).

One-time bootstrap (login node is fine — these are light file ops; heavy compiles go to a dev job):

```bash
# ~/.Renviron on Juno
R_LIBS_USER=~/work/R/library/%v
RENV_PATHS_ROOT=~/work/renv
RENV_PATHS_CACHE=~/work/renv/cache
```

- Home is 300k inodes — R libraries are inode bombs; everything R lives under `~/work`.
- Per project: sync `renv.lock`, then `Rscript -e 'renv::restore()'`. Prefer Posit Package Manager Linux binaries (check `/etc/os-release` for the distro string) to avoid hour-long source compiles; if a package must compile at scale, do it inside a dev job.
- **brms/cmdstanr:** `cmdstanr::install_cmdstan(dir="~/work/cmdstan")` once (dev job); job scripts export `CMDSTAN=~/work/cmdstan/cmdstan-<ver>`.

**Thread rules (encoded in the R template):** exactly ONE level of parallelism.
- R-level parallel (mclapply/future over a grid): workers = `$SLURM_CPUS_PER_TASK`, BLAS pinned to 1 (`OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`).
- Single BLAS-bound fit: invert — `OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK`, workers=1.
- data.table: `R_DATATABLE_NUM_THREADS=$SLURM_CPUS_PER_TASK` (or `setDTthreads(0)` in-script honors it).
- brms: `brm(chains=4, cores=4, threads=threading(cpus/4), backend="cmdstanr", seed=<seed>)`; request `cpus = chains × threads_per_chain`.
- mgcv: `bam(..., discrete=TRUE, nthreads=Sys.getenv("SLURM_CPUS_PER_TASK"))`.

**Honest performance note:** the user's Mac runs Accelerate BLAS (~5× mgcv speedup vs reference); Juno's R likely uses OpenBLAS on EPYC (verify once with `sessionInfo()` on the cluster). Juno wins on *width* (64 cores, 384 GB, multiple concurrent jobs, laptop stays free), not per-core speed. Don't offload single-threaded fits expecting a speedup.

## Python

- `module load miniconda`; envs by path under work: `conda create -p ~/work/envs/<slug> python=3.12` (never `-n` into home).
- `conda init bash; source ~/.bashrc` once, then `conda activate ~/work/envs/<slug>`.
- Heavy env solves and source builds → dev job, not login node.
- Pure Python is serial (GIL): parallelize via numpy/BLAS threads, or pack serial scripts with launcher.
- GPU: install the CUDA-matched torch build inside the env; template handles `module unload gnu14; module load cuda`.

## Stata

- `module load stata/19.5`; batch: `stata-mp -e do script.do` (the `.log` is written next to the do-file, i.e. under `code/` in the scratch dir; the template's cleanup copies both possible locations to results).
- Probe MP license cores once on dev: `stata-mp -q -b 'display c(processors_lic)'` — never request more cores than the license uses.
- Stata outputs: CSVs via `estout`/`putexcel`; there is no `.rds` model object — the cowrite results contract degrades accordingly.

## GPU / CUDA

- `module unload gnu14` (or gnu12) **before** `module load cuda` (toolchain conflict, per the orientation).
- GPU binaries must run on GPU nodes (orientation warns results may be incorrect on nodes without a GPU).
- `--gres=gpu:<n>` is required to see any GPU.
- Partition ladder by VRAM need: 6G→`a30-4.6gb`, 12G→`a30-2.12gb`, 24G→`a30`, >24G→`h200` (26 nodes) before `h100` (3 nodes, scarce).

## Launcher (high-throughput)

- One job, many serial tasks: `module load launcher`; `tasklist.txt` = one shell command per line; `LAUNCHER_PPN` × per-task threads ≤ 64; `$LAUNCHER_DIR/paramrun`.
- Preferred over job arrays for ≤50-task sweeps (one queue entry).

## Containers

- Docker images → Apptainer: convert to `.sif`, run inside a batch job with `apptainer exec --bind $WORKDIR:/work <sif> <cmd>`. No Docker daemon, no root.

## Verify-on-first-connect checklist

Run once after account setup; cache results into `references/juno-live.md` with a date; re-verify after ~90 days or on any mismatch error. Trust live output over any cached fact.

```bash
whoami; echo $HOME; ls -ld ~/scratch ~/work; readlink -f ~/scratch
mfsgetquota -H ~; mfsgetquota -H ~/work; mfsgetquota -H ~/scratch
ls -d /groups/* 2>/dev/null | head        # group dir may not exist yet for a new PI
sinfo -o "%P %l %D %c %m %G"              # partitions vs fact sheet §5
sacctmgr show assoc user=$USER format=account,maxjobs,maxsubmit 2>/dev/null
sshare                                     # fairshare association exists?
module -t avail R python miniconda stata cuda launcher 2>&1 | head -20
cat /etc/os-release | head -2; gcc --version | head -1
# compute-node internet (decides where package installs can run):
#   salloc -p dev -n1 -c1 --mem=2G -t 0:05:00 srun curl -sm5 https://cloud.r-project.org -o /dev/null && echo NET_OK || echo NET_BLOCKED
```
