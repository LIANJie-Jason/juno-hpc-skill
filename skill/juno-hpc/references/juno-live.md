# Juno live-verification cache

> **Status: NOT YET VERIFIED.** This file is the cache for the verify-on-first-connect
> checklist in `software-recipes.md`. Run that checklist once after the account is set up
> (and re-verify after ~90 days or on any mismatch error), then replace this stub with the
> actual output. **Live output always wins over `juno-facts.md`.**

Fill in on first connect:

```
VERIFIED_ON:            <date>
NETID / HOME:           <whoami> / <$HOME>
SCRATCH PATH:           <readlink -f ~/scratch>
QUOTAS (home/work/scratch): <mfsgetquota -H ... >
GROUP DIR:              </groups/<pi> exists? — may not exist for a new PI>
TITAN CONDO:            </titan/<pi> exists?>
PARTITIONS:             <sinfo -o "%P %l %D %c %m %G">
ASSOC LIMITS:           <sacctmgr show assoc user=$USER format=account,maxjobs,maxsubmit>
FAIRSHARE:              <sshare>
MODULES (R/python/miniconda/stata/cuda/launcher): <module -t avail ...>
OS / TOOLCHAIN:         <cat /etc/os-release | head -2; gcc --version | head -1>
COMPUTE-NODE INTERNET:  <NET_OK | NET_BLOCKED>  (decides where package installs run)
R BLAS:                 <Rscript -e 'sessionInfo()' | grep -i blas>
STATA LICENSE CORES:    <stata-mp -q -b 'display c(processors_lic)'>  (only if Stata is used)
DEFAULT MEM SEMANTICS:  <scontrol show config | grep -i defmem>
PRIORITY WEIGHTS:       <scontrol show config | grep -i priority>
```

Discrepancies found vs `juno-facts.md`: _(record them here and patch the fact sheet)_
