# Juno Cluster Fact Sheet (ground truth)

> Distilled from **Juno Orientation v14, Summer 2026 (July 2026)**, HPC@UTD.
> Latest slides: https://hpc.utdallas.edu/systems-resources/juno/
> User guide: https://utdallas-hpc-juno-ug.readthedocs-hosted.com/
> Support: circ-assist@utdallas.edu (AD 3.207, weekdays 9:30–15:30)
> **Facts below can drift — when a command disagrees with this sheet, trust the live system (`sinfo`, `sshare`, `module avail`) and update this sheet.**

## 1. Access

- Login: `ssh <netid>@juno.hpcre.utdallas.edu` (canonical, per account-creation email; `juno.utdallas.edu` also works). Password = NetID password. **NetID is case-sensitive and must be all lowercase** (e.g. `abc123456`, not `ABC123456`).
- Must be on the UTD campus network: campus Ethernet, CometNet WiFi, or the campus VPN.
- Open OnDemand (web, beta): https://juno-ood.hpcre.utdallas.edu/ — file browse/upload/download (10 GB cap), interactive apps (Juno Desktop, JupyterLab, MATLAB, RStudio, VSCode).
- VS Code Remote-SSH: use `juno-vscode.utdallas.edu` (login nodes cap VS Code server at 8 GB RAM and will crash).
- Two login nodes (`juno-l-01`, `juno-l-02`) + head/scheduler node. **Login nodes are for editing, submission, and light file ops only — never for computation. `mpirun` does not work on login nodes.**

## 2. Hardware (orientation headline: 131 nodes, 8,400 cores, 52 TB RAM)

(Headline figures are the orientation's rounded claims; the table below sums to ~130 nodes / ~8,400 cores — the extra node is the dedicated VS Code node. Reconcile against live `sinfo` if it matters.)

| Node type | Count | CPU | Cores | RAM | GPUs |
|---|---|---|---|---|---|
| Login/head | 3 | 2× Xeon Silver 4309Y 2.8 GHz | 8C/16T | 128–384 GB | — |
| CPU compute | 94 | 2× AMD EPYC 9334 2.7 GHz | 64 (2×32C) | 384 GB | — |
| GPU A30 | 4 | 2× AMD EPYC 9534 | 128 (2×64C) | 1,024 GB | 2× A30 (24 GB) |
| GPU H100 | 3 | 2× Xeon Platinum 8462Y | 64 | 512 GB | 4× / 2× / 1× H100 (80/94 GB) |
| GPU H200 | 26 | 2× AMD EPYC 9335 3.0 GHz | 64 (2×32C) | 384 GB | 2× H200 (141 GB, no NVLink) |

Interconnect: HDR100 InfiniBand (100 Gbps); H200 racks NDR 400 Gbps.

## 3. Storage

Three systems: **Scratch** (very high-performance, for I/O during batch jobs), **Io** (high-speed system hosting `~`, `~/work`, and `/groups` — programs and data in active use), and **Titan** (condo long-term storage, also mounted on researcher workstations).

| Space | Path | Quota | Backup | Purpose |
|---|---|---|---|---|
| Home | `~` | 50 GB (55 hard), 300k inodes | daily | configs, login scripts, small software. **Never for batch-job I/O.** |
| Work | `~/work` | 1 TB (1.1 hard), 3.0M inodes | daily | user software, large data, results. OK for light–moderate batch I/O. |
| Group | `/groups/<pi-name>` | 1 TB+ | daily | group-shared software/datasets/results |
| Scratch | `~/scratch` | 30 TB soft | **never** | heavy batch-job I/O; up to 10× faster; **purged: files not accessed for 45 days are deleted** (limit may shrink) |
| Titan condo | `/titan/<pi-name>` | purchased (40 TB+, 20 TB steps) | — | condo long-term storage; mounted on login nodes and researcher workstations (NOT on compute nodes) |

- Quota check: `mfsgetquota -H <dir>` (e.g. `mfsgetquota -H ~/work`). Two quotas: bytes and inodes.
- **Scratch discipline (official policy):** "copy in, read and write during, copy out, and clean up when done":
  1. copy inputs from `~/work` or `/groups` into a per-job dir under `~/scratch`,
  2. do all job I/O there,
  3. copy results back out at the end of the job script,
  4. `rm -rf` the scratch job dir before the job exits.

## 4. Software / modules

- Default modules (July 2026): `autotools prun/2.2 gnu14/14.2.0 hwloc/2.12.0 ucx/1.18.0 libfabric/1.18.0 openmpi5/5.0.7 ohpc`.
- Commands: `module avail`, `module list`, `module load <m>`, `module unload <m>`, `module spider <m>`, `ml -d av` (defaults only).
- Notable modules: `miniconda/24.11.1`, `R/4.5.0`, `python/3.12.2`, `matlab/r2024b`, `stata/19.5`, `cuda/12.4` (11.7–13.0), `launcher/3.9`, `apptainer/1.3.4`, `ollama`, `gaussian/16`, `ansys2025R1`, `gromacs`, `amber`, `openfoam`, `julia/1.11.3`, `java/11`.
- Python: use miniconda envs (`conda create -p <path> python=3.12` recommended, then `conda init bash; source ~/.bashrc; conda activate`). Pure Python is serial (GIL); parallelism via numpy/BLAS threads, `mpi4py`, GPU via PyTorch/CuPy/Numba.
- CUDA compile: `module unload gnu14` (or gnu12) then `module load cuda`. GPU binaries must run on GPU nodes.
- Containers: Docker images must be converted to Apptainer (`.sif`); run via `apptainer exec --bind ...` inside a batch job.
- High-throughput (many small tasks): `module load launcher` + `tasklist.txt` + `$LAUNCHER_DIR/paramrun` (one SLURM job runs N serial tasks across cores; `LAUNCHER_PPN`, `LAUNCHER_NHOSTS`).

## 5. SLURM partitions (from orientation; verify live with `sinfo`)

| Partition | Time limit | Nodes | Max nodes/job | Cores/node | Mem/node | GPUs/node | VRAM |
|---|---|---|---|---|---|---|---|
| `dev` | 2 h | 8 (shared w/ normal) | 4 | 64 | 384 GB | — | — |
| `normal` | 2 days | 92 | 8 | 64 | 384 GB | — | — |
| `h200` | 2 days | 26 | 8 | 64 | 384 GB | 2× H200 | 141 GB |
| `h100` | 2 days | 3 | 1 | 64 | 512 GB | 4×/2×/1× H100 | 80–94 GB |
| `a30` | 2 days | 2 | 2 | 128 | 1,024 GB | 2× A30 | 24 GB |
| `a30-2.12gb` | 2 days | 1 | 1 | 128 | 1,024 GB | 4 half-A30 virtual | 12 GB |
| `a30-4.6gb` | 2 days | 1 | 1 | 128 | 1,024 GB | 8 quarter-A30 virtual | 6 GB |
| `vdi` | 8 h | 2 | 1 | 64 | 384 GB | — | — (GUI/interactive) |

- **Default memory limit if `--mem` unspecified: 64 GB** (orientation value; exact SLURM semantics unverified — **always set `--mem` explicitly**, never rely on the default).
- GPUs require `--gres=gpu:<n>`.
- Partition guidance: compiling/debug/profiling → `dev`; production CPU → `normal`; light GPU → `a30*`; big GPU → `h100`/`h200`; GUI → `vdi` (or OOD).

## 6. User limits (per user, orientation values)

- Max nodes per job: **8**
- Max **running** jobs: **4**
- Max **submitted** (queued+running) jobs: **100**
- Limits can be temporarily relaxed for demonstrated-efficient codes: email circ-assist@utdallas.edu.

## 7. Scheduling priority & fairshare (the "good citizen" math)

```
priority = 100,000 × Fairshare + 1,000 × JobAge + 1,000 × JobSize
```

(Weights are orientation-slide values — treat as directionally exact, verify with `sprio`/`scontrol show config | grep -i Priority` if precision matters. The takeaway is robust either way: fairshare dominates by ~100×.)

- `Fairshare` ∈ [0,1], **shared at the research-group level**; all group members start at 1.0.
- Using the cluster **decreases** the share; idle time restores it — **fully restored in ~2 weeks**; reset to 1.0 at the start of each month.
- `JobAge`: 0 for new jobs → 1 at 14 days queued. `JobSize`: ~0 small → ~1 large (CPUs, memory, time, GPUs).
- Fairshare dominates (100× the other factors) ⇒ **burning fairshare today means slow queues for you and your whole group for up to two weeks.**
- Monitor: `sshare` (own), `sshare -a` (all users; `FairShare` column). `sprio` shows per-job priority components if available.

## 8. Core commands

```bash
sbatch job.sh            # submit; prints "Submitted batch job <id>"
squeue --me              # my queued/running jobs (ST: PD pending, R running)
scancel <jobid>          # cancel
sinfo                    # partitions and node states
sshare [-a]              # fairshare
sacct -j <id> --format=JobID,State,Elapsed,MaxRSS,ExitCode  # accounting/after-the-fact
salloc -p <part> -N 1 -n 1 -c 4 --mem=2G   # interactive allocation
srun --pty bash          # shell on the allocation (prompt shows compute node, e.g. c-04-18)
```

Batch job flow: `sbatch job.sh` → scheduler allocates nodes and runs `job.sh` on the first allocated node → stdout/stderr land in `--output`/`--error` files in the submission directory.

## 9. Canonical job script skeleton (orientation slide 53)

> Reproduced from the orientation deck for reference. Note that **`juno.sh` requires a stricter
> form** than this example: job names must be `[a-z0-9-]` (no underscores) and must equal the job
> filename, and `--output` must be `%x-%j.out`, so the tool can find the log afterwards. Use
> `juno.sh gen` rather than copying this skeleton verbatim.

```bash
#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=6
#SBATCH --mem=30G
#SBATCH --time=3:30:00
#SBATCH --gres=gpu:1            # only if GPUs needed
#SBATCH --partition=h100
#SBATCH --job-name=sim_model_a
#SBATCH --output=sim_model_a_output.txt

module list
module load cuda/12.4

SRC=/groups/.../simulation/     # inputs live on Io
cd ~/scratch && mkdir -p batch_job_a && cd batch_job_a
cp $SRC/inputs .                # 1 copy in
./sim model_a results_a         # 2 compute in scratch
cp results_a $SRC               # 3 copy out
cd .. && rm -rf batch_job_a     # 4 clean up
```

## 10. Publication acknowledgment (required)

Per the account-creation email: **reference HPC@UTD in any research report, journal article, or publication** whose results used Juno resources. Standard line for manuscripts:

> "Computational resources were provided by HPC@UTD, the High Performance Computing group at The University of Texas at Dallas."

Any cowrite project whose empirical results came from Juno jobs must carry this in the acknowledgments.

## 11. What Juno is NOT for

- Not a personal workstation: no GUI on login nodes, no `sudo`.
- Not for small, serial, always-running tasks; not a general-purpose server (web hosting, databases, crypto mining, **persistent AI-inference services**).
- Assumes an established workflow that needs more compute — not spare disk space.
