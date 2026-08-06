# juno-hpc

Claude Code / Codex skill for running computational jobs on UTD's **Juno** HPC cluster (SLURM) from your Mac — automatically, and politely enough that your account never looks aggressive (fairshare-aware throttling, right-sized requests, launcher-packing, 60s-floor polling, scratch hygiene).

## One-time setup (you, ~2 minutes)

```bash
# 1. Be on campus network or the UTD VPN.
# 2. Write the ssh config + key, open the session (types your NetID password once):
skill/juno-hpc/scripts/juno.sh setup <your-netid>     # lowercase, e.g. abc123456
# 3. (optional, recommended for big data) brew install rsync
```

After setup, one `ssh juno true` per work session (password once) gives the agent ~8 hours of scripted access via SSH multiplexing. The agent never sees or stores your password.

## Per-project

```bash
cd <project-root>
<skill>/scripts/juno.sh init      # registers the project, creates remote dirs
```

Then just tell Claude/Codex: *"run `code/05_model.R` on Juno"* — it will size, generate, submit, watch, and fetch per `SKILL.md`.

## Layout

- `SKILL.md` — agent playbook (Claude Code)
- `AGENTS.md` — operational digest (Codex / other CLI agents)
- `scripts/juno.sh` — the entire mechanical layer (bash + ssh + rsync, no dependencies)
- `references/` — cluster fact sheet, good-citizen policy, software recipes, cowrite integration
- `templates/` — sbatch templates (R, Python, Stata, GPU, launcher, generic CPU)

## Publication note

Any paper whose results used Juno must acknowledge HPC@UTD (condition of use):
> "Computational resources were provided by HPC@UTD, the High Performance Computing group at The University of Texas at Dallas."

Support: circ-assist@utdallas.edu · https://hpc.utdallas.edu/
