# Juno live-verification cache

> **VERIFIED 2026-08-06** against the live cluster as `dal004923`.
> Re-verify after ~90 days or on any mismatch error. **Live output always wins over `juno-facts.md`.**

```
NETID / HOME:      dal004923 / /home/dal004923
SCRATCH PATH:      ~/scratch -> /scratch/juno/dal004923   (symlink; separate FS from home)
WORK QUOTA:        1.0 TB soft / 1.1 TB hard · 3.0M inodes soft / 3.1M hard · 0% used
OS:                Rocky Linux 9.5 (Blue Onyx)
FAIRSHARE ACCOUNT: jlian (own account) — FairShare 0.971448 at verification = GREEN
GROUPS DIR:        /groups/<pi> exists cluster-wide; no /groups/jlian yet (new PI)
```

## Confirmed — the policy assumptions all hold

| Claim | Live value | Verdict |
|---|---|---|
| Default memory 64 GB if `--mem` unset | `DefMemPerNode = 65536` (MB, **per node**) | **exact** — the always-set-`--mem` rule is load-bearing |
| Priority = 100,000×FS + 1,000×age + 1,000×size | `PriorityWeightFairShare=100000`, `Age=1000`, `JobSize=1000` | **exact** |
| Max 4 running / 100 submitted per user | QOS `juno`: MaxJobsPU=4, MaxSubmitPU=100 | **exact** (enforced at QOS, not assoc) |

## Partitions (live `sinfo`)

| Partition | Time limit | Nodes | Cores/node | Mem/node | GRES |
|---|---|---|---|---|---|
| `normal`* | 2-00:00:00 | 90 | 64 | 384 GB | — |
| `dev` | 2:00:00 | 8 | 64 | 384 GB | — |
| `a30` | 2-00:00:00 | 2 | 128 | 1024 GB | `gpu:nvidia_a30:2` |
| `a30-2.12gb` | 2-00:00:00 | 1 | 128 | 1024 GB | `gpu:nvidia_a30_2g.12gb:4` |
| `a30-4.6gb` | 2-00:00:00 | 1 | **256** | 1024 GB | `gpu:nvidia_a30_1g.6gb:8` |
| `h100` | 2-00:00:00 | 1+1+1 | 64 | 512 GB | `nvidia_h100_80gb_hbm3:4` / `nvidia_h100_nvl_3g.47gb:4` / `nvidia_h100_nvl:1` |
| `h200` | 2-00:00:00 | 26 | 64 | 384 GB | `gpu:nvidia_h200_nvl:2` |
| `vdi` | 8:00:00 | 2 | 128 | 384 GB | — |

**Drift vs the orientation fact sheet (minor, non-blocking):**
- `normal` is 90 nodes, not 92.
- `a30-4.6gb` reports **256** cores/node, not 128.
- `h100` is three distinct single-node configs, one MIG-partitioned (`3g.47gb`), not a plain 4×/2×/1× split.
- Untyped `--gres=gpu:N` (what `gen` emits) is valid; the typed names above are available if ever needed.

## Additional QOS limits (not in the orientation deck)

```
juno        MaxJobsPU=4    MaxSubmitPU=100     <- the documented per-user caps
juno-dev    MaxJobsPU=1                        <- only ONE running dev job at a time
high-thro+  MaxJobsPU=8    MaxSubmitPU=100
juno-pri    MaxJobsPU=8    MaxSubmitPU=150
large       MaxJobsPU=150  MaxSubmitPU=150
MaxArraySize = 1001                            (arrays exist; this tool still refuses them)
```

**`juno-dev` allows only 1 running job** — smoke tests are serialized by the scheduler. The tool's 2-running default is already stricter than `juno`'s 4, but a *second concurrent dev* smoke test will queue rather than run.

## Modules (live `module avail`)

```
R/4.5.0 · python/3.11.11, 3.12.2 · miniconda/24.11.1 · stata/19.5 · launcher/3.9
cuda/11.7, 12.4, 12.6, 13.0, 13.3
```
Every module name the templates load exists. CUDA now goes to 13.3 (the deck showed 12.4 as default); templates use bare `module load cuda`, which resolves to the site default.

## Still unverified
- Compute-node internet access (decides where package installs can run).
- Stata MP licensed core count (`c(processors_lic)`).
- R's BLAS backend (`sessionInfo()`).
