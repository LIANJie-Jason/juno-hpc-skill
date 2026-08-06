#!/bin/bash
# juno.sh — single CLI entry point for the juno-hpc skill (UTD Juno SLURM cluster).
# Contract: machine-parseable KEY=value lines on stdout; human prose on stderr.
# Every scripted SSH call uses BatchMode=yes and can never hang on a password prompt.
set -euo pipefail

# ---------------------------------------------------------------- constants --
JUNO_HOST_ALIAS="juno"
JUNO_HOSTNAME="juno.hpcre.utdallas.edu"
REMOTE_BASE="work/juno-projects"        # relative to remote $HOME

# Good-citizen policy constants (see references/good-citizen.md)
MAX_RUNNING=2          # self-imposed (system limit: 4)
MAX_PENDING=10         # self-imposed (system limit: 100 submitted)
OVERRIDE_MAX_RUNNING=4 # absolute ceiling even with --override-caps (system limit)
OVERRIDE_MAX_PENDING=25
FS_YELLOW="0.75"       # below: reduced caps 1 running / 5 pending
FS_ORANGE="0.50"       # below: only small jobs (<=8c, <=4h, <=32G) without override
FS_RED="0.25"          # below: refuse without --override-fairshare
YELLOW_MAX_RUNNING=1
YELLOW_MAX_PENDING=5
ORANGE_MAX_CPUS=8
ORANGE_MAX_MEM_MB=32768
ORANGE_MAX_TIME_MIN=240
BURST_N=5              # max submits per BURST_WINDOW seconds
BURST_WINDOW=60
POLL_FLOOR=60          # seconds; never poll squeue faster than this
POLL_CAP=1800          # seconds; max poll interval
MAX_CONN_FAIL=10       # consecutive failed polls tolerated in `wait`
QUOTA_WARN_PCT=80
QUOTA_ABORT_PCT=90     # refuse push at/above this storage usage

PD_RESULT=""
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
RSYNC="$(command -v /opt/homebrew/bin/rsync || command -v /usr/local/bin/rsync || echo /usr/bin/rsync)"
RSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ------------------------------------------------------------------ helpers --
msg() { printf '%s\n' "$*" >&2; }
kv()  { printf '%s\n' "$*"; }
die() { # hint is collapsed to one line so stdout stays strictly KEY=value
  kv "JUNO_ERR=$1"
  kv "JUNO_HINT=$(printf '%s' "$2" | tr '\n\t' '  ')"
  exit "${3:-1}"
}

utcnow() { date -u +%FT%TZ; }
epochnow() { date +%s; }

jssh() { ssh "${SSH_OPTS[@]}" "$JUNO_HOST_ALIAS" "$@"; }

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//'
}

valid_slug() { # pure-bash, whole-string: rejects newlines, spaces, metachars, leading '-'
  case "${1:-}" in ''|*[!a-z0-9-]*|-*) return 1;; esac
  return 0
}

require_jobid() { # numeric-only guard: this value is interpolated into remote commands
  case "${1:-}" in
    ''|*[!0-9]*) die "bad_jobid" "jobid must be numeric, got '${1:-}'" 2;;
  esac
}

sed_escape() { # escape replacement text for sed s|..|..|
  printf '%s' "$1" | sed -e 's/[\\&]/\\&/g' -e 's/|/\\|/g'
}

hash16() { { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | cut -c1-16; }

prune_snapshots() { # bounded local history; must be a no-op (exit 0) on a fresh project.
  # Every pipeline is `|| true`: a missing dir OR an empty grep returns non-zero and would
  # abort submit under `set -euo pipefail` before the trailing `return 0` could run.
  local f d
  { ls -1t .juno/snapshots 2>/dev/null | grep '\.sbatch$' | tail -n +21 || true; } | while IFS= read -r f; do
    [ -n "$f" ] && rm -f ".juno/snapshots/$f"
  done || true
  # bounded payload trees: keep the 10 most recent digests
  { ls -1t .juno/payload 2>/dev/null | grep -v '^\.staging' | tail -n +11 || true; } | while IFS= read -r d; do
    [ -n "$d" ] && rm -rf ".juno/payload/$d"
  done || true
  return 0
}

stage_payload_or_die() {   # sets PD_RESULT; never call inside $( ) — die() must reach stdout
  local rc=0
  stage_payload || rc=$?
  case "$rc" in
    (0) return 0;;
    (3) die "usage" "code/ contains a filename with a newline, which cannot be represented in the staging manifest. Rename it." 2;;
    (4) die "usage" "code/ contains symlink(s) pointing outside the staged tree: $(tr '\n' ' ' < .juno/.badlinks 2>/dev/null). They would arrive broken on Juno — replace them with real files or in-tree links." 2;;
    (*) die "usage" "Could not stage/hash the code/ payload (rsync unavailable or code/ unreadable)." 2;;
  esac
}

stage_payload() { # materialize an immutable local copy of exactly what push would stage,
  # then hash THAT tree. One definition of "the payload": no hash-vs-upload divergence,
  # no TOCTOU against a live code/ dir, and whatever rsync -a really stages is what we hash.
  mkdir -p .juno/payload
  local tmp; tmp=$(mktemp -d ".juno/payload/.staging.XXXXXX") || return 1
  "$RSYNC" -a --exclude-from="$SKILL_DIR/templates/rsync-exclude.txt" "./code/" "$tmp/code/" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  # newline-containing names would make the manifest ambiguous — fail closed
  if ( cd "$tmp" && find . -name '*
*' -print 2>/dev/null | head -1 | grep -q . ); then
    rm -rf "$tmp"; return 3            # newline in a filename
  fi
  # no symlink may escape the staged tree (it would arrive on Juno broken)
  local badlink linkreport
  linkreport=$(mktemp "${TMPDIR:-/tmp}/juno-lk.XXXXXX") || { rm -rf "$tmp"; return 1; }
  # Resolve each link RELATIVE TO ITS OWN DIRECTORY and test real containment: a target
  # containing '..' (or a name like 'dir..txt') is perfectly fine as long as it stays in-tree.
  ( cd "$tmp/code" 2>/dev/null || exit 0
    root=$(pwd -P)
    find . -type l -print 2>/dev/null | while IFS= read -r l; do
      d=$(dirname "$l")
      r=$( cd "$d" 2>/dev/null && cd "$(dirname "$(readlink "$(basename "$l")")")" 2>/dev/null && pwd -P ) || r=""
      if [ -z "$r" ]; then printf '%s (dangling)\n' "$l"; continue; fi
      case "$r/" in
        ("$root"/*) : ;;
        (*) printf '%s -> %s\n' "$l" "$(readlink "$l")" ;;
      esac
    done ) > "$linkreport" 2>/dev/null || true
  badlink=$(head -3 "$linkreport" 2>/dev/null || true)
  rm -f "$linkreport"
  if [ -n "$badlink" ]; then
    rm -rf "$tmp"
    printf '%s' "$badlink" > .juno/.badlinks 2>/dev/null || true
    return 4                           # symlink escaping the staged tree
  fi
  local mf; mf=$(mktemp "${TMPDIR:-/tmp}/juno-mf.XXXXXX") || { rm -rf "$tmp"; return 1; }
  (
    cd "$tmp" || exit 1
    # regular files: one batched hashing pass, NUL-safe, '--' so odd names aren't read as flags
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 -- 2>/dev/null \
      || find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum -- 2>/dev/null
    # modes (full permission bits, not just the exec bit)
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 stat -f 'M %Lp %N' -- 2>/dev/null \
      || find . -type f -print0 | LC_ALL=C sort -z | xargs -0 stat -c 'M %a %n' -- 2>/dev/null
    # symlinks and directories carry structure too
    find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' l; do printf 'L %s -> %s\n' "$l" "$(readlink "$l")"; done
    find . -type d -print0 | LC_ALL=C sort -z | xargs -0 stat -f 'D %Lp %N' -- 2>/dev/null \
      || find . -type d -print0 | LC_ALL=C sort -z | xargs -0 stat -c 'D %a %n' -- 2>/dev/null
  ) > "$mf" || { rm -rf "$tmp"; rm -f "$mf"; return 1; }
  local dg; dg=$(LC_ALL=C sort "$mf" | hash16)
  rm -f "$mf"
  [ -n "$dg" ] || { rm -rf "$tmp"; return 1; }
  if [ -d ".juno/payload/$dg" ]; then rm -rf "$tmp"; else mv "$tmp" ".juno/payload/$dg" || { rm -rf "$tmp"; return 1; }; fi
  PD_RESULT="$dg"
}


mem_to_mb() { # 16G -> 16384 ; 8000M -> 8000 ; bare number = SLURM MiB ; unparsable -> 0
  # K rounds UP to the next MiB, as SLURM does, so a K value can't skim under a cap.
  printf '%s' "$1" | awk '{v=$0
    if(v ~ /^[0-9]+$/){print v; next}
    u=substr(v,length(v),1); n=substr(v,1,length(v)-1)+0
    if(u=="G"||u=="g") print n*1024; else if(u=="M"||u=="m") print n
    else if(u=="T"||u=="t") print n*1048576
    else if(u=="K"||u=="k") print int(n/1024)+((n%1024)>0?1:0)
    else print 0}'
}

time_to_min() { # SLURM forms: MIN | MM:SS | HH:MM:SS | D-HH | D-HH:MM | D-HH:MM:SS ; unparsable -> 0
  # SLURM rounds positive seconds UP to the next minute — mirror that so limits can't be skimmed.
  printf '%s' "$1" | awk '{
    if($0 !~ /^([0-9]+-)?[0-9]+(:[0-9]+){0,2}$/){print 0; next}
    n=split($0,dp,"-"); d=0; rest=$0
    if(n==2){d=dp[1]; rest=dp[2]}
    k=split(rest,t,":"); s=0
    if(n==2){ h=t[1]; m=(k>=2?t[2]:0); s=(k>=3?t[3]:0) }
    else if(k==3){ h=t[1]; m=t[2]; s=t[3] }
    else if(k==2){ h=0; m=t[1]; s=t[2] }
    else { h=0; m=t[1] }
    # SLURM sums fields (they may exceed 59) and rounds leftover seconds UP
    print d*1440+h*60+m+int(s/60)+((s%60)>0?1:0) }'
}

require_project() {
  [ -f .juno/config ] || die "no_project" "Run 'juno.sh init' from the project root first." 20
  # parse, never source: a repo-supplied config must not gain code execution.
  # Take the FULL value after the first '=' so 'SLUG=a=b' fails validation instead of truncating to 'a'.
  SLUG=$(awk '/^SLUG=/{sub(/^SLUG=/,""); print; exit}' .juno/config)
  valid_slug "${SLUG:-}" || die "bad_config" ".juno/config SLUG invalid; re-run 'juno.sh init'." 20
  RDIR="$REMOTE_BASE/$SLUG"
}

require_conn() {
  grep -q "^# >>> juno-hpc >>>" "$HOME/.ssh/config" 2>/dev/null || \
    die "not_setup" "No juno SSH config found. Ask the user to run (interactive, once): scripts/juno.sh setup <netid>" 20
  if ssh -O check "$JUNO_HOST_ALIAS" 2>/dev/null; then return 0; fi
  # stale socket cleanup
  local sock; sock=$(ssh -G "$JUNO_HOST_ALIAS" 2>/dev/null | awk '/^controlpath /{print $2}' || true)
  if [ -n "${sock:-}" ] && [ -S "$sock" ]; then
    ssh -O exit "$JUNO_HOST_ALIAS" 2>/dev/null || rm -f "$sock"
  fi
  local err
  if err=$(ssh "${SSH_OPTS[@]}" "$JUNO_HOST_ALIAS" true 2>&1); then return 0; fi
  case "$err" in
    *"Could not resolve"*|*"timed out"*|*"No route"*|*"Network is unreachable"*|*"Operation timed out"*)
      die "no_network" "Cannot reach $JUNO_HOSTNAME:22. Connect to the UTD VPN (or campus network), then retry once." 11 ;;
    *"Permission denied"*|*"Too many authentication failures"*)
      die "auth_required" "No live SSH session. Ask the user to run: ssh juno true  (password typed once; scripted calls then work for ~8h via ControlMaster)." 10 ;;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      die "hostkey" "Host key problem — STOP and show this to the user; never auto-accept." 13 ;;
    *) die "ssh_failed" "$err" 12 ;;
  esac
}

# ------------------------------------------------------------- subcommands --
cmd_setup() {
  msg "One-time interactive setup. Run this WITH the user present."
  mkdir -p "$HOME/.ssh/cm" && chmod 700 "$HOME/.ssh/cm"
  if ! grep -q "^# >>> juno-hpc >>>" "$HOME/.ssh/config" 2>/dev/null; then
    local netid="${1:-}"
    [ -n "$netid" ] || die "need_netid" "Usage: juno.sh setup <netid>   (lowercase NetID, e.g. abc123456)" 2
    netid=$(printf '%s' "$netid" | tr '[:upper:]' '[:lower:]')
    valid_slug "$netid" || die "bad_netid" "NetID must be alphanumeric, got '$netid'" 2
    sed -e "s|{{NETID}}|$netid|" "$SKILL_DIR/templates/ssh_config_block.txt" >> "$HOME/.ssh/config"
    kv "SSH_CONFIG=updated"
  else
    kv "SSH_CONFIG=already_present"
  fi
  if [ ! -f "$HOME/.ssh/id_ed25519_juno" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_juno" -N "" -C "juno-hpc" >&2
    kv "SSH_KEY=created"
  else
    kv "SSH_KEY=exists"
  fi
  msg "Attempting pubkey install (may prompt for password; cluster may ignore keys — that's OK):"
  ssh-copy-id -i "$HOME/.ssh/id_ed25519_juno.pub" "$JUNO_HOST_ALIAS" >&2 || true
  msg "Opening the multiplexed master (type your NetID password if prompted):"
  ssh "$JUNO_HOST_ALIAS" true
  if ssh -O check "$JUNO_HOST_ALIAS"; then
    kv "JUNO_OK=setup MASTER=live"
  else
    die "setup_failed" "Master socket did not come up; re-run 'ssh juno true' manually." 10
  fi
}

cmd_connect() {
  msg "Opening/refreshing the SSH master (may prompt for password — run in the user's terminal):"
  ssh "$JUNO_HOST_ALIAS" true
  if ssh -O check "$JUNO_HOST_ALIAS"; then
    kv "JUNO_OK=connect MASTER=live"
  else
    die "connect_failed" "Master socket did not come up." 10
  fi
}

cmd_doctor() {
  command -v ssh >/dev/null   && kv "CHECK_SSH=ok"
  kv "CHECK_RSYNC=$RSYNC"
  if grep -q "^# >>> juno-hpc >>>" "$HOME/.ssh/config" 2>/dev/null; then
    kv "CHECK_CONFIG=ok"
  else
    kv "CHECK_CONFIG=missing"
    die "not_setup" "Ask the user to run (interactive, once): scripts/juno.sh setup <netid>" 20
  fi
  if ssh -O check "$JUNO_HOST_ALIAS" 2>/dev/null; then kv "CHECK_SOCKET=alive"; else kv "CHECK_SOCKET=dead"; fi
  require_conn
  kv "CHECK_AUTH=ok"
  local rep
  rep=$(jssh 'echo "REMOTE_USER=$(whoami)"; echo "REMOTE_HOME=$HOME";
    ls -d ~/scratch >/dev/null 2>&1 && echo "CHECK_SCRATCH=ok" || echo "CHECK_SCRATCH=missing";
    ls -d ~/work    >/dev/null 2>&1 && echo "CHECK_WORK=ok"    || echo "CHECK_WORK=missing";
    mfsgetquota -H ~/work 2>/dev/null | tail -n +2 | head -6') || die "remote_failed" "doctor remote probe failed" 30
  kv "---REPORT BEGIN doctor---"
  printf '%s\n' "$rep"
  kv "---REPORT END---"
  kv "JUNO_OK=doctor"
}

cmd_init() {
  local name; name="${1:-$(basename "$PWD")}"
  local slug; slug=$(slugify "$name")
  valid_slug "$slug" || die "bad_slug" "Could not derive a valid slug from '$name'." 2
  mkdir -p .juno/jobs
  [ -f .juno/config ] || printf 'SLUG=%s\nCREATED_UTC=%s\n' "$slug" "$(utcnow)" > .juno/config
  [ -f .juno/jobs.tsv ] || printf '#jobid\tname\tpartition\tsubmit_utc\tstate\tpayload_digest\n' > .juno/jobs.tsv
  [ -f .juno/usage.tsv ] || printf '#jobid\tname\tstate\telapsed\treq_mem_mb\tmax_rss_mb\tsuggest_mem\tpartition\tpayload_digest\n' > .juno/usage.tsv
  grep -q '^\.juno/$' .gitignore 2>/dev/null || printf '.juno/\n' >> .gitignore
  require_conn
  jssh "mkdir -p '$REMOTE_BASE/$slug/code' '$REMOTE_BASE/$slug/data' '$REMOTE_BASE/$slug/results' '$REMOTE_BASE/$slug/jobs'" \
    || die "remote_failed" "Could not create remote project dirs." 30
  kv "JUNO_OK=init"; kv "SLUG=$slug"; kv "REMOTE_DIR=$REMOTE_BASE/$slug"
}

quota_guard() { # $1 = remote dir to check; warns >=80%, aborts >=90%
  # mfsgetquota rows are pipe-delimited: label | curr | soft | percent | hard | percent
  # (orientation slide 18: the percent columns are already percentages, e.g. 0.10 = 0.10%)
  local raw used_pct
  # distinguish "SSH broke" (hard error) from "quota tool unavailable/odd format" (warn)
  raw=$(jssh "mfsgetquota -H $1 2>/dev/null || true") \
    || die "conn_lost" "Quota check failed over SSH (VPN dropped? run: ssh juno true)." 12
  used_pct=$(printf '%s\n' "$raw" | awk -F'|' '$1 ~ /size/ {gsub(/[ \t]/,"",$4); print $4; exit}')
  case "$used_pct" in ''|*[!0-9.]*) used_pct="";; esac
  if [ -n "$used_pct" ]; then
    local pct; pct=$(awk -v p="$used_pct" 'BEGIN{printf "%d", p}')
    kv "QUOTA_USED_PCT=$pct"
    if [ "$pct" -ge "$QUOTA_ABORT_PCT" ]; then
      die "quota" "Remote $1 is at ${pct}% of quota. Run 'juno.sh du' and clean up before pushing." 50
    fi
    if [ "$pct" -ge "$QUOTA_WARN_PCT" ]; then kv "QUOTA_WARN=1"; fi
  else
    kv "QUOTA_UNPARSED=1"
    msg "WARN: could not parse quota for $1 (format drift?) — verify manually: mfsgetquota -H $1"
  fi
  return 0
}

run_rsync() { # wrapper so rsync failures die with a documented code
  "$RSYNC" "$@" || die "rsync_failed" "rsync exited $? — connection lost mid-transfer? Re-run (transfers resume)." 30
}

cmd_push() {
  require_project; require_conn
  quota_guard "~/work"
  run_rsync -az --delete --modify-window=1 \
    --exclude-from="$SKILL_DIR/templates/rsync-exclude.txt" \
    -e "$RSH" -- \
    "./code/" "$JUNO_HOST_ALIAS:$RDIR/code/"
  kv "JUNO_OK=push"; kv "REMOTE_DIR=$RDIR/code"
}

cmd_push_data() {
  require_project; require_conn
  local src="data/processed" cleared="" yes=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift;;
      --cleared-by-user) cleared=1; shift;;
      *) src="$1"; shift;;
    esac
  done
  case "$src" in
    /*|*..*|*$'\n'*) die "bad_path" "push-data source must be a relative project path without '..' (got '$src')." 2;;
  esac
  # the path is interpolated into a remote command: allow only safe characters
  printf '%s' "$src" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._/-]*/?$' \
    || die "bad_path" "push-data source may contain only [A-Za-z0-9._/-] and must start with a letter/digit/underscore (got '$src')." 2
  src="${src%/}"
  [ -d "$src" ] || die "no_data" "Local data dir '$src' not found." 2
  # IRB/data-clearance gate on the PHYSICAL path (a symlinked data/processed can't smuggle raw data)
  local proj phys
  proj=$(pwd -P)
  phys=$(cd "$src" && pwd -P) || die "no_data" "Cannot resolve '$src'." 2
  case "$phys" in
    "$proj"/*) : ;;
    *) die "data_clearance" "'$src' resolves outside the project ($phys). Refusing." 60;;
  esac
  case "$phys" in
    "$proj"/data/processed|"$proj"/data/processed/*) : ;;
    *) [ -n "$cleared" ] || die "data_clearance" "'$src' resolves to '$phys' — outside data/processed (presumed restricted: IRB/DUA/raw). Juno storage is shared university storage with no documented compliance guarantees; scratch purges at 45 days. Get explicit per-dataset user consent, then re-run with --cleared-by-user." 60 ;;
  esac
  # (residual: symlinks INSIDE the tree are copied as links by rsync -a, not followed)
  # size the RESOLVED directory: rsync with a trailing slash follows a symlinked source,
  # while BSD du would report the symlink itself as tiny and skip the confirmation gate
  local sz; sz=$(du -sm "$phys" | awk '{print $1}')
  kv "PAYLOAD_MB=$sz"
  if [ "$sz" -gt 10240 ] && [ -z "$yes" ]; then
    die "confirm_needed" "Payload ${sz}MB > 10GB. Confirm with the user, then re-run with --yes." 60
  fi
  quota_guard "~/work"
  # Mirror the local relative path remotely (data/processed stays data/processed,
  # so scripts using project-root-relative paths keep working unchanged)
  jssh "mkdir -p '$RDIR/$src'" || die "remote_failed" "Could not create remote $RDIR/$src" 30
  run_rsync -az --partial --modify-window=1 -e "$RSH" -- \
    "$src/" "$JUNO_HOST_ALIAS:$RDIR/$src/"
  kv "JUNO_OK=push-data"; kv "REMOTE_DIR=$RDIR/$src"
}

cmd_gen() {
  require_project
  local class="" name="" script="" partition="" cpus="" mem="" time="" gpus="0" args="" module_extra=""
  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "usage" "gen flag $1 needs a value" 2
    case "$1" in
      --class) class="$2"; shift 2;;
      --name) name="$2"; shift 2;;
      --script) script="$2"; shift 2;;
      --partition) partition="$2"; shift 2;;
      --cpus) cpus="$2"; shift 2;;
      --mem) mem="$2"; shift 2;;
      --time) time="$2"; shift 2;;
      --gpus) gpus="$2"; shift 2;;
      --args) args="$2"; shift 2;;
      --modules) module_extra="$2"; shift 2;;
      *) die "usage" "Unknown gen flag: $1" 2;;
    esac
  done
  [ -n "$class" ] && [ -n "$name" ] && [ -n "$script" ] || die "usage" "gen requires --class --name --script" 2
  case "$partition" in
    dev|normal|a30|a30-2.12gb|a30-4.6gb|h100|h200) : ;;
    "") die "usage" "--partition is required (dev|normal|a30|a30-2.12gb|a30-4.6gb|h100|h200)" 2;;
    *) die "bad_partition" "Unknown partition '$partition' (valid: dev normal a30 a30-2.12gb a30-4.6gb h100 h200)" 2;;
  esac
  [ -n "$mem" ]  || die "mem_required"  "--mem is REQUIRED: Juno defaults to 64G if unset (per orientation — a silent over-allocation)." 60
  [ -n "$time" ] || die "time_required" "--time is REQUIRED: never rely on partition max." 60
  [ -n "$cpus" ] || cpus=8
  # strict value formats: these land on #SBATCH lines — a space would smuggle extra directives
  printf '%s' "$cpus" | grep -Eq '^[1-9][0-9]*$' || die "usage" "--cpus must be a positive integer" 2
  printf '%s' "$gpus" | grep -Eq '^(0|[1-9][0-9]*)$' || die "usage" "--gpus must be 0 or a positive integer (no leading zeros)" 2
  printf '%s' "$mem"  | grep -Eq '^[0-9]+[KMGTkmgt]?$' || die "usage" "--mem must look like 16G / 8000M / 65536" 2
  printf '%s' "$time" | grep -Eq '^([0-9]+-)?[0-9]+(:[0-9]{2}){0,2}$' || die "usage" "--time must be a SLURM time (02:00:00, 1-00:00:00, 300)" 2
  [ "$(mem_to_mb "$mem")" -gt 0 ]    || die "usage" "--mem must be > 0 (SLURM treats 0 as ALL node memory)" 2
  [ "$(time_to_min "$time")" -gt 0 ] || die "usage" "--time must be > 0 (SLURM treats 0 as no limit)" 2
  # script/args/modules are substituted into shell command lines in the job: strict allowlists.
  # --script: project-relative path only (no leading '-', no '..', no absolute).
  printf '%s' "$script" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9._/-]*$' \
    || die "usage" "--script must be a project-relative path starting with a letter/digit/underscore ([A-Za-z0-9._/-])" 2
  case "$script" in *..*) die "usage" "--script must not contain '..'" 2;; esac
  case "$script" in */-*|-*) die "usage" "--script filename must not start with '-' (it would be read as a command flag)" 2;; esac
  case "$script" in */./*|*//*) die "usage" "--script must be a normalized path (no './' or '//' segments)" 2;; esac
  # Only code/ (and optionally data/) are staged to the cluster, so the entry point must live
  # under code/ and must actually exist — otherwise the job fails at runtime after queueing.
  case "$script" in
    code/*) : ;;
    *) die "usage" "--script must be under code/ (only code/ and data/ are synced to Juno); got '$script'." 2;;
  esac
  [ -f "$script" ] || die "usage" "--script '$script' does not exist locally. Create it (and 'juno.sh push') before generating the job." 2
  # the entrypoint must be a real file inside code/ (not a symlink out of the tree: rsync -a
  # copies the link, not its target) and must survive the actual push filter
  [ -L "$script" ] && die "usage" "--script '$script' is a symlink. rsync copies the link, not its target, so the job would find a broken path on Juno. Use the real file under code/." 2
  local script_phys code_phys
  code_phys=$(cd code && pwd -P)
  script_phys=$(cd "$(dirname "$script")" && pwd -P)/$(basename "$script")
  case "$script_phys" in
    "$code_phys"/*) : ;;
    *) die "usage" "--script '$script' resolves outside code/ ($script_phys). rsync copies symlinks as links, so the target would be missing on Juno. Put the real file under code/." 2;;
  esac
  # dry-run the REAL push filter and confirm this file appears in the transfer list
  local rel_path check_dir xfer
  rel_path="${script#code/}"
  check_dir=$(mktemp -d "${TMPDIR:-/tmp}/juno-genchk.XXXXXX")
  # capture the full transfer list first: piping into `grep -q` can SIGPIPE rsync, and under
  # `pipefail` that would look like "file excluded" for a perfectly included file
  local rrc=0
  xfer=$("$RSYNC" -rn --out-format='%n' --exclude-from="$SKILL_DIR/templates/rsync-exclude.txt" \
        "./code/" "$check_dir/" 2>/dev/null) || rrc=$?
  rm -rf "$check_dir"
  [ "$rrc" -eq 0 ] || die "usage" "Could not verify staging: rsync dry-run failed (exit $rrc). Check that '$RSYNC' works and code/ is readable." 2
  # here-string (temp file), not a pipe: `grep -q` exits on first match and would SIGPIPE a
  # producing pipeline, which under pipefail reads as "file excluded"
  grep -Fxq -- "$rel_path" <<<"$xfer" \
    || die "usage" "--script '$script' would be filtered out by templates/rsync-exclude.txt, so 'juno.sh push' would never upload it. Move it out of the excluded subtree." 2
  # --args: allowlist (flags, values, quoted phrases) — no shell metacharacters at all
  if [ -n "$args" ]; then
    printf '%s' "$args" | grep -Eq '^[A-Za-z0-9 ._,:=/@+"-]*$' \
      || die "usage" "--args may contain only [A-Za-z0-9 ._,:=/@+\"-] (no shell metacharacters)" 2
    [ $(( $(printf '%s' "$args" | tr -cd '"' | wc -c) % 2 )) -eq 0 ] \
      || die "usage" "--args has an unbalanced double quote" 2
  fi
  # --modules: only module load/unload statements
  if [ -n "$module_extra" ]; then
    printf '%s' "$module_extra" | grep -Eq '^module (load|unload) [A-Za-z0-9._/+-]+( *; *module (load|unload) [A-Za-z0-9._/+-]+)*$' \
      || die "usage" "--modules must be 'module load X' / 'module unload X' statements (semicolon-separated)" 2
  fi
  # class/partition/GPU coherence: GPU work needs a GPU partition, CPU partitions get no GRES
  local is_gpu_partition=""
  case "$partition" in a30|a30-2.12gb|a30-4.6gb|h100|h200) is_gpu_partition=1;; esac
  if [ "$class" = "gpu" ] && [ -z "$is_gpu_partition" ]; then
    die "usage" "--class gpu requires a GPU partition (a30 | a30-2.12gb | a30-4.6gb | h100 | h200), got '$partition'." 2
  fi
  if [ "$gpus" != "0" ] && [ -z "$is_gpu_partition" ]; then
    die "usage" "--gpus $gpus on non-GPU partition '$partition': no GPUs exist there. Use a GPU partition or drop --gpus." 2
  fi
  if [ -n "$is_gpu_partition" ] && [ "$gpus" = "0" ]; then
    die "gpus_required" "Partition '$partition' is a GPU partition but --gpus is 0: the job would occupy a scarce GPU node without a GPU (--gres is mandatory on Juno). Add --gpus 1." 60
  fi
  name=$(slugify "$name"); valid_slug "$name" || die "bad_name" "Job name must slugify to [a-z0-9-]." 2
  for v in "$script" "$args" "$module_extra" "$mem" "$time" "$cpus" "$gpus"; do
    case "$v" in *$'\n'*) die "usage" "newlines not allowed in gen arguments" 2;; esac
  done
  if [ "$class" = "launcher" ] && [ -n "$args" ]; then
    die "usage" "--args has no effect for --class launcher: each line of the tasklist ($script) carries its own command and arguments. Put the arguments in the tasklist." 2
  fi
  local tmpl="$SKILL_DIR/templates/job.${class}.sbatch.tmpl"
  [ -f "$tmpl" ] || die "no_template" "No template for class '$class' at $tmpl" 2
  # fingerprint the entrypoint so the smoke-test gate proves THIS script was tested,
  # not merely that some earlier script reused the same job name
  local fp
  fp=$( { shasum -a 256 "$script" 2>/dev/null || sha256sum "$script" 2>/dev/null; } | cut -c1-16)
  [ -n "$fp" ] || die "usage" "Could not fingerprint '$script' (no shasum/sha256sum available)." 2
  stage_payload_or_die; local pd="$PD_RESULT"
  local out=".juno/jobs/${name}.sbatch"
  if [ "$gpus" = "0" ]; then
    sed -e '/^{{GRES_LINE}}$/d' \
        -e "s|{{NAME}}|$(sed_escape "$name")|g" \
        -e "s|{{PARTITION}}|$(sed_escape "$partition")|g" \
        -e "s|{{CPUS}}|$(sed_escape "$cpus")|g" \
        -e "s|{{MEM}}|$(sed_escape "$mem")|g" \
        -e "s|{{TIME}}|$(sed_escape "$time")|g" \
        -e "s|{{SLUG}}|$(sed_escape "$SLUG")|g" \
        -e "s|{{SCRIPT}}|$(sed_escape "$script")|g" \
        -e "s|{{ARGS}}|$(sed_escape "$args")|g" \
        -e "s|{{MODULES_EXTRA}}|$(sed_escape "$module_extra")|g" \
        -e "s|{{PAYLOAD_DIGEST}}|$(sed_escape "$pd")|g" \
        "$tmpl" > "$out"
  else
    sed -e "s|{{GRES_LINE}}|#SBATCH --gres=gpu:$(sed_escape "$gpus")|g" \
        -e "s|{{NAME}}|$(sed_escape "$name")|g" \
        -e "s|{{PARTITION}}|$(sed_escape "$partition")|g" \
        -e "s|{{CPUS}}|$(sed_escape "$cpus")|g" \
        -e "s|{{MEM}}|$(sed_escape "$mem")|g" \
        -e "s|{{TIME}}|$(sed_escape "$time")|g" \
        -e "s|{{SLUG}}|$(sed_escape "$SLUG")|g" \
        -e "s|{{SCRIPT}}|$(sed_escape "$script")|g" \
        -e "s|{{ARGS}}|$(sed_escape "$args")|g" \
        -e "s|{{MODULES_EXTRA}}|$(sed_escape "$module_extra")|g" \
        -e "s|{{PAYLOAD_DIGEST}}|$(sed_escape "$pd")|g" \
        "$tmpl" > "$out"
  fi
  # Stamp BOTH the entry-point hash and a hash of the wrapper body itself, so editing the
  # wrapper (e.g. to run a different script) invalidates the gate just like editing the script.
  local wfp
  # guarantee a newline separator even if a template lacks a trailing newline
  [ -z "$(tail -c1 "$out")" ] || printf '\n' >> "$out"
  wfp=$(hash16 < "$out")
  printf '# juno-fingerprint: %s %s %s %s\n' "$fp" "$script" "$wfp" "$pd" >> "$out"
  kv "JUNO_OK=gen"; kv "SCRIPT=$out"; kv "FINGERPRINT=$fp"; kv "WRAPPER_FINGERPRINT=$wfp"; kv "PAYLOAD_DIGEST=$pd"
  msg "Review $out before submitting (scratch discipline, modules, threads)."
}

count_jobs() { # sets RUNNING_N and PENDING_N from one squeue call; dies on conn failure
  local q
  # -t all: squeue's default filter hides some active states we need to count
  if ! q=$(jssh 'squeue --me -t all --noheader -o "%T"'); then
    die "conn_lost" "Could not query squeue — cannot verify job caps. Reconnect and retry." 12
  fi
  # COMPLETING/CONFIGURING jobs still hold an allocation — count them as running
  # Fail CLOSED on unknown states/flags: anything that is not definitively finished counts
  # as active, so a state or flag we don't recognise can never license an extra submission.
  local terminal='^(COMPLETED|CANCELLED|FAILED|TIMEOUT|OUT_OF_MEMORY|NODE_FAIL|BOOT_FAIL|DEADLINE|PREEMPTED|REVOKED)'
  PENDING_N=$(printf '%s\n' "$q" | grep -E '^[A-Z]' | grep -cE '^(PENDING|REQUEUED|REQUEUE_HOLD|REQUEUE_FED|RESV_DEL_HOLD|SPECIAL_EXIT)' || true)
  RUNNING_N=$(printf '%s\n' "$q" | grep -E '^[A-Z]' | grep -vE "$terminal" \
              | grep -vE '^(PENDING|REQUEUED|REQUEUE_HOLD|REQUEUE_FED|RESV_DEL_HOLD|SPECIAL_EXIT)' | grep -c . || true)
}

fairshare() { # prints FS value or "unknown"
  local fs
  fs=$(jssh 'sshare -U -n -P --format=FairShare 2>/dev/null | head -1' || echo "unknown")
  fs=$(printf '%s' "$fs" | tr -d ' ')
  printf '%s' "${fs:-unknown}"
}

fs_below() { # fs_below <fs> <threshold> -> exit 0 if fs < threshold (numeric)
  awk -v f="$1" -v t="$2" 'BEGIN{exit !((f+0)<(t+0))}'
}

cmd_budget() {
  require_project; require_conn
  count_jobs
  local fs; fs=$(fairshare)
  kv "FAIRSHARE=$fs"; kv "RUNNING=$RUNNING_N"; kv "PENDING=$PENDING_N"
  local advice="ok" cap_r=$MAX_RUNNING cap_p=$MAX_PENDING
  if [ "$fs" != "unknown" ]; then
    if fs_below "$fs" "$FS_RED"; then advice="pause"
    elif fs_below "$fs" "$FS_ORANGE"; then advice="throttle"; kv "ORANGE_MAX=8c/4h/32G"
    elif fs_below "$fs" "$FS_YELLOW"; then advice="reduce"; cap_r=$YELLOW_MAX_RUNNING; cap_p=$YELLOW_MAX_PENDING
    fi
    # fairshare drift tracking (alert the user on drops > 0.15 between sessions)
    local prev=""
    [ -f .juno/fairshare.log ] && prev=$(tail -1 .juno/fairshare.log | cut -f2)
    printf '%s\t%s\n' "$(utcnow)" "$fs" >> .juno/fairshare.log
    if [ -n "$prev" ]; then
      kv "FS_PREV=$prev"
      kv "FS_DROP=$(awk -v a="$prev" -v b="$fs" 'BEGIN{printf "%.3f", a-b}')"
    fi
  fi
  kv "CAP_RUNNING=$cap_r"; kv "CAP_PENDING=$cap_p"
  kv "ADVICE=$advice"; kv "JUNO_OK=budget"
}

burst_guard() {
  local now n
  now=$(epochnow)
  touch .juno/submits.log
  n=$(awk -v now="$now" -v w="$BURST_WINDOW" '$1 >= now-w' .juno/submits.log | wc -l | tr -d ' ')
  if [ "$n" -ge "$BURST_N" ]; then
    die "guard_burst" "$n submits in the last ${BURST_WINDOW}s (cap $BURST_N). Pack tasks into one launcher job, or wait a minute." 60
  fi
  return 0
}

# A job counts as a smoke test only if it is small AND on a smoke partition.
# `dev` (2h, no GPUs) is the CPU smoke partition; the fractional-A30 partitions are the GPU
# smoke partitions — but those are also 2-day production queues, so size limits apply there.
SMOKE_MAX_MIN=30; SMOKE_MAX_CPUS=8; SMOKE_MAX_MEM_MB=32768; SMOKE_MAX_GPUS=1
is_smoke_job() { # $1=partition $2=total_cpus $3=mem_mb $4=time_min $5=gpus
  case "$1" in
    dev|a30-4.6gb|a30-2.12gb) : ;;
    *) return 1;;
  esac
  # size limits apply on every smoke partition, so a big job there can't inherit the
  # gate/fairshare exemptions just by picking a small-sounding queue
  [ "${4:-99999}" -le "$SMOKE_MAX_MIN" ] || return 1
  [ "${2:-99}" -le "$SMOKE_MAX_CPUS" ] || return 1
  [ "${3:-999999}" -le "$SMOKE_MAX_MEM_MB" ] || return 1
  [ "${5:-0}" -le "$SMOKE_MAX_GPUS" ] || return 1
  return 0
}

dev_gate() { # $1=payload digest $2=target partition; production needs a COMPLETED smoke row for THIS payload
  local ok_parts smoke_hint
  case "$2" in
    # GPU production must be preceded by a run that actually exercised a GPU — a `dev` row
    # proves nothing about GPU code, so dev is deliberately NOT accepted here.
    a30|a30-2.12gb|a30-4.6gb|h100|h200)
      ok_parts="a30-4.6gb a30-2.12gb"
      smoke_hint="GPU smoke test: --partition a30-4.6gb --gpus 1 --time 00:15:00 --cpus 4 --mem 8G (dev has no GPUs)";;
    *)
      ok_parts="dev"
      smoke_hint="dev smoke test: --partition dev --time 00:15:00 --cpus 4 --mem 8G";;
  esac
  # exact string membership (never interpolate partition names into a regex)
  if ! awk -F'\t' -v f="$1" -v parts="$ok_parts" '
      BEGIN{ k=split(parts,a," "); for(i=1;i<=k;i++) ok[a[i]]=1 }
      $9==f && $3 ~ /^COMPLETED/ && ($8 in ok) { found=1 }
      END{ exit !found }' .juno/usage.tsv 2>/dev/null; then
    die "guard_devgate" "No COMPLETED smoke-test run of THIS code payload (digest $1) on a suitable partition (${ok_parts// /, }). Smoke-test the exact payload first on subsampled data, then 'juno.sh post <id>'. $smoke_hint. Changing ANY staged file under code/ changes the digest and requires a fresh smoke test. Override only with explicit user approval: --skip-dev-gate." 60
  fi
  return 0
}

cmd_submit() {
  require_project; require_conn
  local jobfile="" override_fs="" skip_devgate="" override_caps="" claim_smoke=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --override-fairshare) override_fs=1; shift;;
      --skip-dev-gate) skip_devgate=1; shift;;
      --override-caps) override_caps=1; shift;;
      --smoke) claim_smoke=1; shift;;
      *) jobfile="$1"; shift;;
    esac
  done
  [ -f "$jobfile" ] || die "usage" "Usage: juno.sh submit .juno/jobs/<name>.sbatch [--smoke|--override-fairshare|--skip-dev-gate|--override-caps]" 2
  local name; name=$(basename "$jobfile" .sbatch)
  # SNAPSHOT FIRST, then validate the snapshot and upload those exact bytes: validating the
  # mutable path and copying later leaves a window where the file could change in between.
  mkdir -p .juno/snapshots
  prune_snapshots
  local snap; snap=".juno/snapshots/${name}-$(epochnow)-$$.sbatch"
  cp "$jobfile" "$snap"
  jobfile="$snap"
  valid_slug "$name" || die "bad_name" "Job filename must slugify to [a-z0-9-].sbatch (got '$name'). Use juno.sh gen." 2

  # --- policy guards (references/good-citizen.md) ---
  # SLURM only honors #SBATCH directives in the prologue (before the first executable line),
  # so we (a) scan EXACTLY that prologue — late fake directives can't fool the guard because
  # SLURM ignores them too — and (b) require every directive in canonical one-'--opt=value'-
  # per-line form, as juno.sh gen emits. Anything else (short forms, space-separated values,
  # tabs, multi-option lines) is refused outright: fail closed, regenerate with gen.
  local prologue bad legacy
  # sbatch honors comment lines (incl. leading whitespace) until the first executable line
  prologue=$(awk 'NR==1{next} /^[[:space:]]*$/{print; next} /^[[:space:]]*#/{print; next} {exit}' "$jobfile")
  # sbatch also parses legacy "#SLURM" directives — refuse them rather than guess
  # sbatch also parses #SLURM, and #PBS/#BSUB (unless --ignore-pbs) — all would carry resource
  # requests our allowlist never sees. Refuse them here AND pass --ignore-pbs at submit time.
  legacy=$(printf '%s\n' "$prologue" | grep -E '^[[:space:]]*#(SLURM|PBS|BSUB)' || true)
  [ -z "$legacy" ] || die "guard_format" "Foreign scheduler directive(s) found: [$legacy]. sbatch honors #SLURM/#PBS/#BSUB lines, which bypass this tool's resource guards. Use canonical #SBATCH lines only (regenerate with juno.sh gen)." 60
  # plain comments (with or without leading whitespace) are fine; only #SBATCH lines must be canonical
  # ALLOWLIST: only the directives juno.sh gen emits are permitted. Anything else — including
  # perfectly valid SLURM options like --tres-per-task=cpu=64 (which would allocate CPUs the
  # accounting below cannot see) or --parsable/--quiet (which change sbatch's output format and
  # would break jobid parsing) — is refused, because a guard can only police what it parses.
  bad=$(printf '%s\n' "$prologue" | grep -E '^[[:space:]]*#SBATCH' \
    | grep -Ev '^#SBATCH --(nodes|ntasks|ntasks-per-node|cpus-per-task|mem|time|partition|job-name|output)=[^[:space:]]+$|^#SBATCH --gres=gpu(:[A-Za-z0-9_.-]+)?:[0-9]+$' || true)
  [ -z "$bad" ] || die "guard_format" "Unsupported or non-canonical #SBATCH line(s): [$bad]. Only these directives are allowed, one '--opt=value' per line: nodes, ntasks, ntasks-per-node, cpus-per-task, mem, time, partition, gres, job-name, output. Regenerate with juno.sh gen." 60
  # ANCHORED extraction: the option must be the directive itself, not a substring of some
  # other option's value (e.g. '#SBATCH --comment=--nodes=1' must not masquerade as --nodes).
  sbatch_opt() { printf '%s\n' "$prologue" | grep -E "^#SBATCH $1=" | tail -1 | sed -E 's/^#SBATCH [^=]+=//' || true; }
  sbatch_has() { printf '%s\n' "$prologue" | grep -Eq "^#SBATCH $1(=|$)"; }
  local partition cpus mem_raw time_raw mem_mb time_min nodes gres_gpus ntasks total_cpus jobname
  mem_raw=$(sbatch_opt '\-\-mem');  time_raw=$(sbatch_opt '\-\-time')
  [ -n "$mem_raw" ]  || die "guard_mem"  "Job script has no #SBATCH --mem (64G silent default = over-allocation)." 60
  [ -n "$time_raw" ] || die "guard_time" "Job script has no #SBATCH --time." 60
  partition=$(sbatch_opt '\-\-partition')
  # exactly one known partition (SLURM accepts comma lists; those would defeat the routing below)
  case "$partition" in
    dev|normal|a30|a30-2.12gb|a30-4.6gb|h100|h200) : ;;
    "") die "guard_format" "Job script has no #SBATCH --partition. Regenerate with juno.sh gen." 60;;
    *) die "guard_format" "--partition='$partition' must be exactly one of: dev normal a30 a30-2.12gb a30-4.6gb h100 h200 (comma lists are not supported). Regenerate with juno.sh gen." 60;;
  esac
  cpus=$(sbatch_opt '\-\-cpus-per-task')
  nodes=$(sbatch_opt '\-\-nodes')
  jobname=$(sbatch_opt '\-\-job-name')
  local ntasks_total ntasks_per_node output_opt gpu_lines unsupported_gpu
  ntasks_total=$(sbatch_opt '\-\-ntasks')
  ntasks_per_node=$(sbatch_opt '\-\-ntasks-per-node')
  output_opt=$(sbatch_opt '\-\-output')
  # node count must be a plain integer (ranges like 1-8 would coerce to 1 and undercount)
  if [ -n "$nodes" ]; then
    printf '%s' "$nodes" | grep -Eq '^[1-9][0-9]*$' \
      || die "guard_format" "--nodes='$nodes' must be a plain integer (ranges are not supported). Regenerate with juno.sh gen." 60
  fi
  # GPU accounting across every spelling, with per-task/per-node/per-socket multiplication.
  # Any GPU-ish directive we can't interpret is refused rather than silently counted as zero.
  # only gpu-typed GRES counts as a GPU request (e.g. --gres=bandwidth:2 is not GPUs)
  gpu_lines=$(printf '%s\n' "$prologue" | grep -E '^#SBATCH --(gres=gpu|gpus(-per-(node|task|socket))?=)' | sed -E 's/^#SBATCH //' || true)
  unsupported_gpu=$(printf '%s\n' "$gpu_lines" | grep -E -- '^--(gres=gpu|gpus)' \
    | grep -Ev -- '^--(gres=gpu(:[A-Za-z0-9_.-]+)?:[0-9]+|gpus(-per-(node|task|socket))?=([A-Za-z0-9_.-]+:)?[0-9]+)$' || true)
  [ -z "$unsupported_gpu" ] || die "guard_format" "Unrecognized GPU request syntax: [$unsupported_gpu]. Use juno.sh gen (--gpus N) so the GPU cap can be evaluated." 60
  gres_gpus=$(printf '%s\n' "$gpu_lines" | awk -v nt="${ntasks_total:-}" -v ntpn="${ntasks_per_node:-}" -v nd="${nodes:-1}" '
    function num(s){ sub(/^.*[:=]/,"",s); return s+0 }
    { n=num($0)
      if ($0 ~ /--gpus-per-task=/)        { t=(nt!=""?nt:(ntpn!=""?ntpn*nd:1)); n=n*t }
      else if ($0 ~ /--gpus-per-node=/)   { n=n*(nd==""?1:nd) }
      else if ($0 ~ /--gpus-per-socket=/) { n=n*2*(nd==""?1:nd) }   # 2 sockets/node on Juno
      else if ($0 ~ /--gres=gpu/)         { n=n*(nd==""?1:nd) }     # gres is per node
      if (n>max) max=n }
    END{ printf "%d", max }')
  [ "$gres_gpus" = "0" ] && gres_gpus=""
  # Total cores: global --ntasks is allocation-wide; --ntasks-per-node multiplies by nodes.
  total_cpus=$(awk -v c="${cpus:-1}" -v nt="${ntasks_total:-}" -v ntpn="${ntasks_per_node:-}" -v n="${nodes:-1}" 'BEGIN{
    c=(c==""?1:c)+0; n=(n==""?1:n)+0; if(c<1)c=1; if(n<1)n=1
    if(nt!="")        t=nt+0
    else if(ntpn!="") t=(ntpn+0)*n
    else              t=n
    if(t<1)t=1
    v=c*t; if(v<1)v=1; print v}')
  # Require the same canonical forms gen emits: out-of-range fields (e.g. 1:99999) make
  # minute/second interpretation ambiguous, so refuse rather than guess at the limit.
  printf '%s' "$mem_raw"  | grep -Eq '^[0-9]+[KMGTkmgt]?$' \
    || die "guard_format" "--mem='$mem_raw' is not a canonical SLURM size (16G / 8000M / 65536). Regenerate with juno.sh gen." 60
  printf '%s' "$time_raw" | grep -Eq '^([0-9]+-)?[0-9]+(:[0-9]{2}){0,2}$' \
    || die "guard_format" "--time='$time_raw' is not a canonical SLURM time (02:00:00 / 1-00:00:00 / 300; two-digit sub-fields). Regenerate with juno.sh gen." 60
  # SLURM --mem is PER NODE: the job's real footprint is mem × nodes
  mem_mb=$(awk -v m="$(mem_to_mb "$mem_raw")" -v n="${nodes:-1}" 'BEGIN{n=(n==""?1:n)+0; if(n<1)n=1; printf "%d", m*n}')
  time_min=$(time_to_min "$time_raw")
  # SLURM special values: --mem=0 = ALL node memory, --time=0 = no limit. Refuse both (and unparsable).
  [ "${mem_mb:-0}" -gt 0 ]  || die "guard_mem"  "--mem='$mem_raw' is zero or unparsable (SLURM treats 0 as ALL node memory). Set a real value." 60
  [ "${time_min:-0}" -gt 0 ] || die "guard_time" "--time='$time_raw' is zero or unparsable (SLURM treats 0 as no limit). Set a real value." 60
  # job-name and output must be canonical, or logs/post/dev-gate bookkeeping silently diverges
  # (juno.sh reads the log at $RDIR/jobs/<name>-<jobid>.out, i.e. --output=%x-%j.out)
  [ "$jobname" = "$name" ] || \
    die "guard_name" "#SBATCH --job-name must be '$name' (got '${jobname:-<missing>}') — log lookup, post, and the dev gate all key on it. Regenerate with juno.sh gen." 60
  [ "$output_opt" = "%x-%j.out" ] || \
    die "guard_name" "#SBATCH --output must be '%x-%j.out' (got '${output_opt:-<missing>}') — otherwise 'juno.sh logs' tails the wrong path. Regenerate with juno.sh gen." 60
  # GPU partitions must actually request a GPU
  case "$partition" in
    a30|a30-2.12gb|a30-4.6gb|h100|h200)
      [ -n "$gres_gpus" ] || die "guard_gpus" "Partition '$partition' is a GPU partition but the script requests no GPU (--gres/--gpus). The job would occupy a scarce GPU node without using its GPU." 60;;
    *)
      [ -z "$gres_gpus" ] || die "guard_gpus" "Partition '$partition' has no GPUs, but the script requests $gres_gpus (--gres=gpu). The job would never start. Use a GPU partition or drop the GPU request." 60;;
  esac
  # Arrays are refused outright (no override): squeue compresses pending array elements so the
  # job caps under-count them, and array element IDs (<jobid>_<task>) don't match the numeric
  # $SLURM_JOB_ID scratch naming that clean-scratch relies on. Launcher packing is the answer.
  if sbatch_has '\-\-array'; then
    die "guard_array" "Job arrays are not supported by this tool: pack 5-50 tasks into ONE launcher-class job (good-citizen.md §2). Arrays would evade the job caps (squeue compresses pending elements) and break scratch cleanup (element IDs are <jobid>_<task>). If an array is genuinely unavoidable, the user runs it manually and manages its scratch." 60
  fi
  # documented default: <=16 cores unless measured (good-citizen.md §1)
  if [ "$total_cpus" -gt 16 ] && [ -z "$override_caps" ]; then
    die "guard_cores" "$total_cpus total cores requested; the skill default is <=16 unless the scaling is measured (good-citizen.md §1). A full-node launcher job packing many tasks is the expected exception — confirm the core count with the user, then re-run with --override-caps." 60
  fi
  # (--exclusive is not in the directive allowlist above, so it can never reach here)
  if [ -n "$nodes" ]; then
    case "$nodes" in
      1) : ;;
      *) [ -n "$override_caps" ] || die "guard_nodes" "--nodes='$nodes' (multi-node or range). Requires an articulated MPI need + explicit user approval: --override-caps." 60;;
    esac
  fi
  if [ -n "$gres_gpus" ] && [ "$gres_gpus" -gt 1 ]; then
    [ -n "$override_caps" ] || die "guard_gpus" "$gres_gpus GPUs requested (default cap: 1). Requires explicit user approval: --override-caps." 60
  fi

  burst_guard
  # fingerprint recorded by gen; ties the smoke-test gate to this exact script version
  local fp fp_path wfp pd stamp_n wfp_now pd_now
  # EXACTLY ONE stamp, and it must be the final line — otherwise a second stamp could name a
  # tested script while a different body runs
  stamp_n=$(grep -c '^# juno-fingerprint: ' "$jobfile" || true)
  [ "$stamp_n" -eq 1 ] || die "guard_format" "Expected exactly one '# juno-fingerprint:' line, found $stamp_n. Regenerate with juno.sh gen." 60
  [ "$(tail -1 "$jobfile" | cut -c1-20)" = "# juno-fingerprint: " ] || die "guard_format" "The '# juno-fingerprint:' stamp must be the last line of the job file. Regenerate with juno.sh gen." 60
  set -- $(tail -1 "$jobfile")
  fp="${3:-}"; fp_path="${4:-}"; wfp="${5:-}"; pd="${6:-}"
  [ -n "$fp" ] && [ -n "$fp_path" ] && [ -n "$wfp" ] && [ -n "$pd" ] || die "guard_format" "Malformed fingerprint stamp (need '<hash> <path> <wrapper-hash> <payload-digest>'). Regenerate with juno.sh gen." 60
  # wrapper body unmodified (everything above the stamp line)
  wfp_now=$(sed '$d' "$jobfile" | hash16)
  [ "$wfp_now" = "$wfp" ] || die "guard_format" "This job file was edited after generation (wrapper hash $wfp, now $wfp_now). The guards validate what 'gen' produced, so hand-edited wrappers are refused — re-run 'juno.sh gen' with the options you want." 60
  # the whole staged payload (not just the entry point) must match what was fingerprinted,
  # so a changed helper/import also invalidates the gate
  stage_payload_or_die; pd_now="$PD_RESULT"
  [ "$pd_now" = "$pd" ] || die "guard_format" "The code/ payload changed since this job was generated (digest $pd, now $pd_now). Re-run 'juno.sh gen' (and smoke-test the new payload) before submitting." 60
  # RECOMPUTE: a stamped hash is only a claim. Verify it still matches the file on disk,
  # so an edited script (or a hash pasted from another wrapper) cannot ride an old gate pass.
  [ -f "$fp_path" ] || die "guard_format" "Fingerprinted entry point '$fp_path' no longer exists locally. Regenerate the job with juno.sh gen." 60
  fp_now=$( { shasum -a 256 "$fp_path" 2>/dev/null || sha256sum "$fp_path" 2>/dev/null; } | cut -c1-16)
  [ "$fp_now" = "$fp" ] || die "guard_format" "Entry point '$fp_path' changed since this job file was generated (stamped $fp, now $fp_now). Re-run 'juno.sh gen' (and smoke-test the new version) before submitting." 60
  # Smoke status requires EXPLICIT intent (--smoke) as well as a smoke partition and size,
  # so ordinary small production work can't silently live outside the gate forever.
  local smoke=""
  if [ -n "$claim_smoke" ]; then
    is_smoke_job "${partition:-normal}" "$total_cpus" "${mem_mb:-0}" "${time_min:-0}" "${gres_gpus:-0}" \
      || die "guard_smoke" "--smoke claimed but the job exceeds the smoke envelope (partition must be dev/a30-4.6gb/a30-2.12gb; <=${SMOKE_MAX_MIN}min, <=${SMOKE_MAX_CPUS} cores, <=$((SMOKE_MAX_MEM_MB/1024))G, <=${SMOKE_MAX_GPUS} GPU). This job: ${partition}/${time_min}min/${total_cpus}c/${mem_mb}MB/${gres_gpus:-0}gpu." 60
    smoke=1
  fi
  # gate on the PAYLOAD digest: it covers the entry point and every helper that gets staged
  [ -n "$skip_devgate" ] || [ -n "$smoke" ] || dev_gate "$pd" "${partition:-normal}"

  count_jobs
  kv "RUNNING=$RUNNING_N"; kv "PENDING=$PENDING_N"
  local fs; fs=$(fairshare); kv "FAIRSHARE=$fs"
  local cap_r=$MAX_RUNNING cap_p=$MAX_PENDING
  # Fail CLOSED: an unreadable sshare must not silently grant GREEN behavior.
  if [ "$fs" = "unknown" ] && [ -z "$smoke" ] && [ -z "$override_fs" ]; then
    die "guard_fairshare" "Could not read the group's FairShare (sshare unavailable). The throttle cannot be evaluated, so production submits are refused. Retry, or with user approval: --override-fairshare (smoke-sized jobs on dev/a30-4.6gb/a30-2.12gb are always allowed)." 60
  fi
  if [ "$fs" != "unknown" ]; then
    if fs_below "$fs" "$FS_RED"; then
      if [ -z "$smoke" ] && [ -z "$override_fs" ]; then
        die "guard_fairshare" "Group FairShare=$fs < $FS_RED (RED). Queues will crawl for the whole group for up to 2 weeks. Smoke-sized tests (dev / a30-4.6gb / a30-2.12gb) are still allowed; anything else needs explicit user approval: --override-fairshare." 60
      fi
    elif fs_below "$fs" "$FS_ORANGE"; then
      if [ -z "$override_fs" ] && [ -z "$smoke" ]; then
        # fail CLOSED: unparsable mem/time (0) counts as oversized
        if [ "$total_cpus" -gt "$ORANGE_MAX_CPUS" ] || [ "${mem_mb:-0}" -gt "$ORANGE_MAX_MEM_MB" ] || [ "${mem_mb:-0}" -eq 0 ] \
           || [ "${time_min:-0}" -gt "$ORANGE_MAX_TIME_MIN" ] || [ "${time_min:-0}" -eq 0 ]; then
          die "guard_fairshare" "FairShare=$fs (ORANGE): only small jobs (<=8 cores, <=4h, <=32G) auto-submit. This job: ${total_cpus}c/${time_min:-?}min/${mem_mb:-?}MB (0 = unparsable, treated as over). Ask the user, then --override-fairshare." 60
        fi
      fi
    elif fs_below "$fs" "$FS_YELLOW"; then
      cap_r=$YELLOW_MAX_RUNNING; cap_p=$YELLOW_MAX_PENDING
      kv "MODE=YELLOW"
    fi
  fi
  if [ -n "$override_caps" ]; then cap_r=$OVERRIDE_MAX_RUNNING; cap_p=$OVERRIDE_MAX_PENDING; fi
  if [ "$RUNNING_N" -ge "$cap_r" ]; then
    die "guard_jobs" "Running cap reached ($RUNNING_N/$cap_r). Wait for a job to finish, pack into a launcher job, or (with explicit user approval, ceiling 4) --override-caps." 60
  fi
  if [ "$PENDING_N" -ge "$cap_p" ]; then
    die "guard_jobs" "Pending cap reached ($PENDING_N/$cap_p). Let the queue drain, or (with user approval, ceiling 25) --override-caps." 60
  fi

  # Upload the exact bytes we validated, under a unique remote name: re-reading $jobfile here
  # would let it change between validation and upload, and a shared remote filename lets two
  # submits clobber each other.
  # Stage an IMMUTABLE per-payload code snapshot the job will copy from, so a later `push`
  # (or a forgotten one) cannot change what an already-queued job executes.
  quota_guard "~/work"
  jssh "mkdir -p '$RDIR/snapshots/$pd'" || die "remote_failed" "Could not create the remote code snapshot dir." 30
  [ -d ".juno/payload/$pd/code" ] || die "usage" "Local payload snapshot .juno/payload/$pd is missing; re-run juno.sh gen." 2
  run_rsync -az --delete --modify-window=1 -e "$RSH" -- \
    ".juno/payload/$pd/code/" "$JUNO_HOST_ALIAS:$RDIR/snapshots/$pd/code/"
  local remote_name
  remote_name="${name}-$(hash16 < "$jobfile").sbatch"
  run_rsync -az -e "$RSH" -- "$jobfile" "$JUNO_HOST_ALIAS:$RDIR/jobs/${remote_name}"
  local out
  # Strip SBATCH_* from the remote environment: SLURM lets those env vars OVERRIDE the
  # directives we just validated (e.g. SBATCH_TRES_PER_TASK, SBATCH_ARRAY_INX, SBATCH_PARTITION),
  # which would silently defeat every guard above.
  # Scrub scheduler env overrides (SBATCH_* plus the documented SLURM_* sbatch inputs; SLURM_CONF
  # is left alone because sbatch needs it to find the cluster config) and ignore #PBS/#BSUB lines.
  out=$(jssh "for v in \$(env | sed -n 's/^\(SBATCH_[A-Za-z0-9_]*\)=.*/\1/p'); do unset \"\$v\"; done
              unset SLURM_HINT SLURM_CLUSTERS SLURM_ACCOUNT SLURM_PARTITION SLURM_DISTRIBUTION \\
                    SLURM_EXCLUSIVE SLURM_JOB_NAME SLURM_NETWORK SLURM_NTASKS SLURM_CPUS_PER_TASK \\
                    SLURM_MEM_PER_NODE SLURM_MEM_PER_CPU SLURM_TIMELIMIT SLURM_GRES SLURM_NNODES 2>/dev/null || true
              cd '$RDIR/jobs' && sbatch --ignore-pbs '${remote_name}'" 2>&1) || die "sbatch_failed" "$out" 30
  local jobid; jobid=$(printf '%s' "$out" | sed -n 's/^Submitted batch job \([0-9][0-9]*\).*/\1/p')
  [ -n "$jobid" ] || die "parse_failed" "$out" 30
  printf '%s\n' "$(epochnow)" >> .juno/submits.log
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$jobid" "$name" "${partition:-unknown}" "$(utcnow)" "SUBMITTED" "$pd" >> .juno/jobs.tsv
  kv "JUNO_OK=submitted"; kv "JOBID=$jobid"; kv "NAME=$name"; kv "PAYLOAD_DIGEST=$pd"
  kv "LOG=$RDIR/jobs/${name}-${jobid}.out"
  if [ -n "$smoke" ]; then kv "SMOKE=1"; fi
  # keep the local snapshot dir bounded
  prune_snapshots
  return 0
}

status_probe() { # $1 = jobid or "" for all
  jssh bash -s "${1:-}" <<'REMOTE'
id="${1:-}"
sq_rc=0; sa_rc=0
echo "=SQUEUE="
if [ -n "$id" ]; then squeue -j "$id" -t all --noheader -o '%i|%j|%P|%T|%M|%l|%R' 2>/dev/null || sq_rc=$?
else                  squeue --me     -t all --noheader -o '%i|%j|%P|%T|%M|%l|%R' 2>/dev/null || sq_rc=$?; fi
echo "=SACCT="
if [ -n "$id" ]; then
  sacct -n -X -P -j "$id" --format=JobID,JobName%30,Partition,State,Elapsed,ExitCode 2>/dev/null || sa_rc=$?
else
  sacct -n -X -P --starttime "$(date -d '-3 days' +%F)" --format=JobID,JobName%30,Partition,State,Elapsed,ExitCode 2>/dev/null || sa_rc=$?
fi
echo "=RC="
echo "SQUEUE_RC=$sq_rc"
echo "SACCT_RC=$sa_rc"
REMOTE
}

cmd_status() {
  require_project; require_conn
  if [ -n "${1:-}" ]; then require_jobid "$1"; fi
  local probe
  probe=$(status_probe "${1:-}") || die "conn_lost" "Status query failed (VPN dropped? run: ssh juno true)." 12
  kv "---REPORT BEGIN status---"
  printf '%s\n' "$probe" | sed -n '1,/^=RC=/p' | sed '$d'
  kv "---REPORT END---"
  # report each scheduler command's real exit status: an empty result and a failed query
  # must not look the same
  local sq_rc sa_rc
  sq_rc=$(printf '%s\n' "$probe" | sed -n 's/^SQUEUE_RC=//p' | tail -1)
  sa_rc=$(printf '%s\n' "$probe" | sed -n 's/^SACCT_RC=//p' | tail -1)
  kv "SQUEUE_RC=${sq_rc:-unknown}"; kv "SACCT_RC=${sa_rc:-unknown}"
  if [ "${sq_rc:-0}" != "0" ] || [ "${sa_rc:-0}" != "0" ]; then
    die "scheduler_error" "Scheduler query failed (squeue rc=${sq_rc:-?}, sacct rc=${sa_rc:-?}) — results may be incomplete. Retry; if it persists the controller may be down." 30
  fi
  if ! printf '%s\n' "$probe" | sed -n '1,/^=RC=/p' | grep -q '^[0-9]'; then
    kv "NO_JOBS=1"
  fi
  kv "JUNO_OK=status"
}

job_state() { # $1=jobid -> prints STATE from probe (squeue wins, else sacct)
  local probe sq st
  probe=$(status_probe "$1")
  sq=$(printf '%s\n' "$probe" | sed -n '/^=SQUEUE=/,/^=SACCT=/p' | grep '^[0-9]' | head -1 | cut -d'|' -f4 || true)
  if [ -n "$sq" ]; then printf '%s' "$sq"; return; fi
  st=$(printf '%s\n' "$probe" | sed -n '/^=SACCT=/,/^=RC=/p' | grep '^[0-9]' | head -1 | cut -d'|' -f4 || true)
  printf '%s' "${st:-UNKNOWN}"
}

cmd_wait() {
  require_project
  local jobid="${1:-}"; require_jobid "$jobid"
  local poll=120
  if [ "${2:-}" = "--poll" ]; then
    [ -n "${3:-}" ] || die "usage" "--poll needs a value (seconds)" 2
    printf '%s' "$3" | grep -Eq '^[1-9][0-9]*$' || die "usage" "--poll must be a positive integer (seconds)" 2
    poll="$3"
  fi
  [ "$poll" -lt "$POLL_FLOOR" ] && poll=$POLL_FLOOR
  [ "$poll" -gt "$POLL_CAP" ] && poll=$POLL_CAP
  local n=0 fails=0 state=""
  while :; do
    n=$((n+1))
    state=$(job_state "$jobid" 2>/dev/null) || state="UNKNOWN"
    # UNKNOWN covers ssh failure, missing accounting record, AND a nonexistent jobid —
    # all must count toward the give-up limit or this loop never terminates.
    if [ "$state" = "UNKNOWN" ]; then
      fails=$((fails+1))
      msg "WARN=no_state n=$fails (conn lost, jobid unknown, or accounting lag)"
      if [ "$fails" -ge "$MAX_CONN_FAIL" ]; then
        die "no_state_during_wait" "No job state for $fails consecutive polls. EITHER the connection is down (VPN? run: ssh juno true) and the job is still running — just re-run 'juno.sh wait $jobid' — OR job $jobid does not exist / never reached accounting. Check 'juno.sh status $jobid' to tell which." 41
      fi
    else
      fails=0
      kv "POLL_N=$n"; kv "POLL_JOBID=$jobid"; kv "POLL_STATE=$state"
      case "$state" in
        COMPLETED*) kv "JUNO_FINAL=1"; kv "STATE=COMPLETED"; kv "NEXT=juno.sh post $jobid && juno.sh fetch"; exit 0;;
        FAILED*|CANCELLED*|TIMEOUT*|OUT_OF_MEMORY*|NODE_FAIL*|BOOT_FAIL*|DEADLINE*|PREEMPTED*)
          kv "JUNO_FINAL=1"; kv "STATE=$state"
          cmd_logs "$jobid" --tail 50 || true
          exit 40;;
      esac
    fi
    sleep "$poll"
  done
}

cmd_logs() {
  require_project; require_conn
  local jobid="${1:-}"; require_jobid "$jobid"
  local tail_n=200
  if [ "${2:-}" = "--tail" ] && [ -n "${3:-}" ]; then tail_n="$3"; fi
  case "$tail_n" in *[!0-9]*) die "usage" "--tail must be numeric" 2;; esac
  local name; name=$(awk -F'\t' -v j="$jobid" '$1==j{print $2}' .juno/jobs.tsv 2>/dev/null | head -1)
  if [ -z "$name" ]; then
    local sacct_out
    sacct_out=$(jssh "sacct -n -X -P -j $jobid --format=JobName%40") \
      || die "conn_lost" "Name lookup failed over SSH (VPN dropped? run: ssh juno true)." 12
    name=$(printf '%s\n' "$sacct_out" | head -1 | tr -d ' ')
  fi
  if [ -z "$name" ] || ! valid_slug "$name"; then
    die "unknown_job" "Cannot resolve job $jobid to a log name (not in .juno/jobs.tsv, sacct lookup failed)." 20
  fi
  local logtext
  logtext=$(jssh "tail -n $tail_n '$RDIR/jobs/${name}-${jobid}.out' 2>/dev/null || echo '(no log yet)'") \
    || die "conn_lost" "Log fetch failed (VPN dropped? run: ssh juno true)." 12
  kv "---LOG BEGIN jobid=$jobid---"
  printf '%s\n' "$logtext"
  kv "---LOG END---"
}

cmd_post() {
  require_project; require_conn
  local jobid="${1:-}"; require_jobid "$jobid"
  local rep
  rep=$(jssh "sacct -n -P -j $jobid --format=JobID,JobName,State,Elapsed,ReqMem,MaxRSS,ExitCode,NTasks,AllocCPUS") \
    || die "remote_failed" "sacct query failed" 30
  [ -n "$(printf '%s' "$rep" | tr -d '[:space:]')" ] || \
    die "no_accounting" "sacct returned nothing for job $jobid (not yet in accounting, or wrong id). Retry in a minute." 30
  local state elapsed reqmem maxrss_mb reqmem_mb name
  name=$(printf '%s\n' "$rep" | head -1 | cut -d'|' -f2)
  state=$(printf '%s\n' "$rep" | head -1 | cut -d'|' -f3)
  elapsed=$(printf '%s\n' "$rep" | head -1 | cut -d'|' -f4)
  reqmem=$(printf '%s\n' "$rep" | head -1 | cut -d'|' -f5)
  # MaxRSS lives on step rows (.batch); take max across rows, normalize K/M/G/T to MB
  maxrss_mb=$(printf '%s\n' "$rep" | cut -d'|' -f6 | awk '
    /[0-9]/ { v=$0; u=substr(v,length(v),1); n=substr(v,1,length(v)-1)+0
      if(u=="K") m=n/1024; else if(u=="M") m=n; else if(u=="G") m=n*1024; else if(u=="T") m=n*1048576; else m=(v+0)/1048576
      if(m>mx) mx=m } END{printf "%d", mx}')
  # ReqMem may carry a per-node/per-cpu suffix (16Gn, 4000Mc) — strip it first
  reqmem_mb=$(printf '%s' "$reqmem" | awk '{v=$0; sub(/[nc]$/,"",v)
    u=substr(v,length(v),1); n=substr(v,1,length(v)-1)+0
    if(u=="G") print n*1024; else if(u=="M") print n; else if(u=="T") print n*1048576; else print 0}')
  # MaxRSS is the peak of a single TASK, not the job total. For multi-task jobs a
  # 1.5x-of-one-task suggestion would under-size, so report per-task and withhold SUGGEST_MEM.
  local ntasks_max; ntasks_max=$(printf '%s\n' "$rep" | cut -d'|' -f8 | awk '{n=$0+0; if(n>m)m=n} END{printf "%d", m}')
  local suggest_mem="-" util="-"
  if [ "${maxrss_mb:-0}" -gt 0 ]; then
    if [ "${ntasks_max:-0}" -le 1 ]; then
      # 1.5x headroom, matching good-citizen.md §3
      suggest_mem=$(awk -v m="$maxrss_mb" 'BEGIN{s=m*1.5/1024; g=int(s)+(s>int(s)); if(g<4)g=4; printf "%dG", g}')
    else
      suggest_mem="per-task-only"
    fi
    if [ "${reqmem_mb:-0}" -gt 0 ] && [ "${ntasks_max:-0}" -le 1 ]; then
      util=$(awk -v a="$maxrss_mb" -v b="$reqmem_mb" 'BEGIN{printf "%d%%", a*100/b}')
    elif [ "${ntasks_max:-0}" -gt 1 ]; then
      util="per-task-only"   # MaxRSS is one task's peak; dividing by the job-wide request lies
    fi
  fi
  local part fp
  part=$(awk -F'\t' -v j="$jobid" '$1==j{print $3}' .juno/jobs.tsv 2>/dev/null | head -1)
  fp=$(awk -F'\t' -v j="$jobid" '$1==j{print $6}' .juno/jobs.tsv 2>/dev/null | head -1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$jobid" "$name" "$state" "$elapsed" "${reqmem_mb:-0}" "${maxrss_mb:-0}" "$suggest_mem" "${part:-unknown}" "${fp:-unknown}" >> .juno/usage.tsv
  kv "JUNO_OK=post"; kv "STATE=$state"; kv "ELAPSED=$elapsed"
  kv "MAXRSS_MB_PER_TASK=${maxrss_mb:-0}"; kv "NTASKS=${ntasks_max:-1}"
  kv "REQMEM_MB=${reqmem_mb:-0}"; kv "REQMEM_RAW=${reqmem:-}"; kv "UTIL=$util"
  kv "SUGGEST_MEM=$suggest_mem"
  if [ "$suggest_mem" = "per-task-only" ]; then
    msg "NOTE: multi-task job (${ntasks_max} tasks) — MaxRSS is per task; size the next request from concurrent-task totals, not 1.5x this number."
  fi
  return 0
}

cmd_fetch() {
  require_project; require_conn
  local sub="${1:-}"
  if [ -n "$sub" ]; then
    valid_slug "$sub" || die "usage" "fetch [subdir] — subdir must be a simple slug name ([a-z0-9-])" 2
  fi
  mkdir -p "results/${sub:-}"
  run_rsync -az --partial --modify-window=1 -e "$RSH" -- \
    "$JUNO_HOST_ALIAS:$RDIR/results/${sub:+$sub/}" "results/${sub:+$sub/}"
  kv "JUNO_OK=fetch"; kv "DEST=results/${sub:-}"
}

cmd_cancel() {
  require_project; require_conn
  local jobid="${1:-}"; require_jobid "$jobid"
  jssh "scancel $jobid" || die "remote_failed" "scancel failed" 30
  kv "JUNO_OK=cancelled"; kv "JOBID=$jobid"
}

cmd_du() {
  require_project; require_conn
  local rep
  rep=$(jssh "du -sh $RDIR/* 2>/dev/null; echo; mfsgetquota -H ~/work 2>/dev/null | head -8") \
    || die "conn_lost" "Remote du failed (VPN dropped? run: ssh juno true)." 12
  kv "---REPORT BEGIN du---"
  printf '%s\n' "$rep"
  kv "---REPORT END---"
  kv "JUNO_OK=du"
}

cmd_clean_scratch() {
  require_project; require_conn
  [ "${1:-}" = "--yes" ] || die "confirm_needed" "Lists then removes ~/scratch/${SLUG}-* dirs with no running job. Re-run with --yes after user confirmation." 60
  # Only delete when squeue positively ANSWERS that the job is gone. A squeue failure
  # (controller down / transient error) must never be read as "job absent".
  local out rc=0
  out=$(jssh "set -eu
        live=\$(mktemp \"\${TMPDIR:-/tmp}/juno_live.XXXXXX\")
        trap 'rm -f \"\$live\"' EXIT
        if ! squeue -h -u \"\$USER\" -t all -o %i > \"\$live\" 2>/dev/null; then
          echo 'SQUEUE_UNAVAILABLE=1'; exit 3; fi
        fails=0
        for d in ~/scratch/${SLUG}-*; do
          [ -d \"\$d\" ] || continue
          id=\${d##*-}
          case \"\$id\" in ''|*[!0-9]*) echo \"SKIP_NONJOB=\$d\"; continue;; esac
          # match bare ids AND array element ids (<jobid>_<task>)
          if grep -qE \"^\${id}(_|\\\$)\" \"\$live\"; then continue; fi
          if rm -rf \"\$d\"; then echo \"REMOVED=\$d\"; else echo \"REMOVE_FAILED=\$d\"; fails=1; fi
        done
        [ \"\$fails\" -eq 0 ]") || rc=$?
  printf '%s\n' "$out"
  case "$rc" in
    0) kv "JUNO_OK=clean-scratch";;
    3) die "squeue_unavailable" "squeue could not be read, so no scratch dir was deleted (refusing to guess which jobs are live). Retry later." 30;;
    *) die "cleanup_failed" "Remote cleanup reported failures (see REMOVE_FAILED lines above)." 30;;
  esac
}

cmd_help() {
  cat <<'EOF'
juno.sh — UTD Juno HPC automation (see SKILL.md / AGENTS.md)
  setup <netid>       one-time interactive setup (ssh config + key + master)   [human]
  connect             open/refresh SSH master (may prompt for password)        [human]
  doctor              connectivity + remote sanity + quota report
  init [name]         register this project (.juno/, remote dirs)
  budget              fairshare + caps + advice (ok|reduce|throttle|pause) + FS_DROP
  push                rsync ./code -> remote code/ (mirror)
  push-data [dir]     rsync data (data/processed only, unless --cleared-by-user; >10GB needs --yes)
  gen --class r|python|stata|gpu|launcher|cpu --name N --script S   (cpu = bash script)
      --partition P --cpus C --mem M --time T [--gpus G] [--args A] [--modules M]
  submit <file> [--smoke|--override-fairshare|--skip-dev-gate|--override-caps]
                      --smoke: claim smoke-test status (needs a smoke partition dev/a30-4.6gb/
                      a30-2.12gb + <=30min, <=8c, <=32G, <=1 GPU); exempt from the fingerprint
                      gate and from the RED / unreadable-sshare fairshare refusals
                      guards: allowlisted #SBATCH directives only, mem/time present,
                      burst<=5/min, payload-digest smoke-test gate, no arrays,
                      caps 2 running/10 pending (1/5 in YELLOW), fairshare bands
  status [jobid]      one-shot squeue+sacct snapshot
  wait <jobid> [--poll 120]   local polling loop (floor 60s), conn-loss tolerant
  logs <jobid> [--tail N]     tail the SLURM output file
  post <jobid>        sacct MaxRSS/Elapsed -> right-sizing suggestion (feeds the smoke gate)
  fetch [subdir]      rsync remote results/ -> local results/
  cancel <jobid>      scancel
  du                  remote project sizes + quota (use when exit 50)
  clean-scratch --yes remove own orphaned scratch dirs
Exit codes: 0 ok | 2 usage | 10 auth | 11 no network/VPN | 12 ssh/conn other | 13 hostkey |
            20 state/setup | 30 remote or rsync fail | 40 job failed |
            41 wait gave up with no state: EITHER conn lost (job still running -> re-run wait)
               OR the job never existed; run 'status <jobid>' to tell which |
            50 quota (run 'du', clean up) | 60 policy guard (read JUNO_ERR: guard_* needs user
            approval; *_required = fix invocation; confirm_needed/data_clearance = ask user)
Output: KEY=value on stdout, except fenced blocks (---LOG BEGIN/END---, ---REPORT BEGIN/END---).
EOF
}

# ------------------------------------------------------------------ dispatch --
sub="${1:-help}"; shift || true
case "$sub" in
  setup) cmd_setup "$@";;
  connect) cmd_connect "$@";;
  doctor) cmd_doctor "$@";;
  init) cmd_init "$@";;
  budget) cmd_budget "$@";;
  push) cmd_push "$@";;
  push-data) cmd_push_data "$@";;
  gen) cmd_gen "$@";;
  submit) cmd_submit "$@";;
  status) cmd_status "$@";;
  wait) cmd_wait "$@";;
  logs) cmd_logs "$@";;
  post) cmd_post "$@";;
  fetch) cmd_fetch "$@";;
  cancel) cmd_cancel "$@";;
  du) cmd_du "$@";;
  clean-scratch) cmd_clean_scratch "$@";;
  help|--help|-h|--list-commands) cmd_help;;
  *) die "usage" "Unknown subcommand '$sub'. Run: juno.sh help" 2;;
esac
