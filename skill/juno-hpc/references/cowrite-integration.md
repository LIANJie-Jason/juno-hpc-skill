# Cowrite Integration Contract (academic-cowriter compatibility)

**Positioning: juno-hpc is an execution backend, never an author.** In the academic-cowriter architecture, analysis code is authored and gated by `empirical-helper`'s A1–A6 pipeline (A6 = Codex gate). juno-hpc slots in *after* A6, at the execution step of empirical-helper Phase 4/5 or robustness-checker Phase 5. It replaces "run locally" with "run on Juno" and nothing else.

## Hard rules

1. **Never touch `drafts/`** — `init_draft.docx` is canonical and read-only to everything except cowrite. `drafts/`, `lit review/`, `docs/`, `logs/` are excluded from every rsync (see `templates/rsync-exclude.txt`).
2. **Never author or modify analysis scripts.** If a script won't run remotely (absolute path, missing package), report the blocker to the calling skill; the fix goes through empirical-helper's A1→A6 loop. This preserves the one-new-script-per-analysis convention.

   Note on what travels: the only things ever synced are `code/` (whole tree, minus build/VCS junk — see `templates/rsync-exclude.txt`) and data paths you pass explicitly to `push-data`. `drafts/`, `docs/`, `logs/`, `lit review/`, and `results/` are siblings of `code/` and are never part of a sync source, so `init_draft.docx` and the logs cannot leave the laptop through this tool.
3. **The only files juno-hpc generates are thin SLURM wrappers** in `.juno/jobs/` — never mixed into the numbered `code/` pipeline.
4. **Byte-identical output contract.** Results land at the *same relative paths* under the project root as a local run would produce (jobs write into `results/`, `juno.sh fetch` pulls `results/` back). Downstream skills (`publishable-tables`, `empirical-report`, the gate ledger) must not be able to tell where the fit ran — except via the logs.
5. **Replication capture travels with every job** (robustness-checker R3 requirement): each template writes `results/replication/environment_juno_<jobid>.txt` (sessionInfo/pip freeze + `module list` + hostname). Seeds are set in the analysis scripts themselves (cowrite convention), not by the wrapper.

## Offload decision rule

Run **locally** when ALL hold: est. runtime < 30 min AND peak RAM < 8 GB; or the work is interactive/iterative (model development, debugging); or it's rendering/tables/plots/docx (publishable-tables territory — always local).

Offload to **Juno** when ANY hold: est. runtime > 1–2 h local; RAM beyond the Mac; embarrassingly parallel batch (multiverse, bootstrap ≥1,000 iterations, robustness batteries); multi-chain brms fits > ~1 h; anything that would pin the laptop during working hours. Jobs needing > 48 h must be chunked/checkpointed to fit the 2-day partition limit first.

**Remember:** Juno wins on width, not per-core speed (Mac Accelerate BLAS vs cluster OpenBLAS). Don't offload single-threaded fits expecting a speedup.

## Data clearance gate (HARD BLOCK)

- **IRB/DUA/PII data never leaves the laptop without explicit per-dataset user confirmation.** Presume RESTRICTED for: survey microdata, anything under `data/raw/` whose docs mention IRB, DUA, embargo, restricted, human subjects.
- When asking, tell the user plainly: Juno `~/scratch` and `~/work` are shared university storage not documented as meeting any compliance standard (treat as non-compliant for IRB/DUA purposes); scratch is purged at 45 days. Mechanical backstop: `juno.sh push-data` refuses any source outside `data/processed` without `--cleared-by-user`.
- Public country-year panels (V-Dem, ACLED, WDI, etc.) are `public` and flow freely.
- Record the clearance decision in the WORKLOG entry.

## Handoff spec

The calling skill provides (conversationally or as a note in `docs/todo.md`):
- script path (e.g. `code/robustness/r_5_estimator.R`), language, entry command if nonstandard
- inputs to sync (`data/processed/...` subsets — never all of `data/`)
- expected outputs (relative `results/...` paths)
- resource estimate (cores/mem/time; juno-hpc right-sizes per good-citizen.md, seeded by `.juno/usage.tsv` history)
- round id + A6 gate status — **the agent must confirm the A6 gate passed before calling `submit`** (the CLI cannot check this itself; record the gate status in the WORKLOG entry as the attestation)
- data clearance (public | user-confirmed | RESTRICTED)

juno-hpc returns to the calling skill:
- local results paths (fetched)
- `juno.sh post` resource report (State, Elapsed, MaxRSS, utilization, SUGGEST_MEM)
- log excerpt on failure (auto-tailed by `wait`)
- fairshare after the run (`juno.sh budget`)
- verdict COMPLETED | FAILED | TIMEOUT | OOM — on failure, diagnosis goes back to the calling skill (A3 leads debugging); juno-hpc does not self-fix analysis code

Stata caveat: no `.rds` model objects from Stata runs — the results contract degrades to CSVs/logs; robustness-checker's cross-language reproducibility route should expect this.

## Logging conventions

- `logs/WORKLOG.md` (detailed, per job): submitted spec + A6 gate status, partition/resources, runtime + MaxRSS + utilization, synced outputs, environment-capture path, SLURM log path, fairshare after, data-clearance note.
- `logs/COWORK_LOG.md` (one line): `- [date] juno-hpc: <script> executed on Juno (job <id>, <elapsed>, clean exit); outputs in results/ — see WORKLOG.`
- `logs/gate_ledger.csv` (if the project keeps one): add rows with gate code `HPC` — `artifact, producing_script, check_id, HPC, PASS|FAIL, date, round`.
- `docs/todo.md`: only for jobs that outlive the session (`T-N: Juno job <id> (<script>) — running`, flipped to Done with the resource summary on retrieval). Never touch cowrite-owned structures (Section Progress, Round Pipeline, Round History).

## Publication acknowledgment (required by HPC@UTD)

Any manuscript whose results came from Juno jobs **must** acknowledge HPC@UTD (condition of use, per the account-creation email). When a cowrite project first fetches Juno results that feed the paper, add a todo (and remind the user) to include in the acknowledgments:

> "Computational resources were provided by HPC@UTD, the High Performance Computing group at The University of Texas at Dallas."
