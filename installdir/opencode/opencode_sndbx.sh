#!/usr/bin/env bash
# =============================================================================
# opencode_sndbx.sh — CHPC bubblewrap sandbox wrapper for OpenCode
#
# University of Utah — Center for High Performance Computing
# https://www.chpc.utah.edu/
#
# PURPOSE
#   This script is the user-facing "opencode" command installed by the Lmod
#   module. It launches the real OpenCode binary inside a bubblewrap (bwrap)
#   sandbox that constrains what the AI agent can read, write, and reach on
#   the network — without requiring root or Docker.
#
# HOW IT IS USED
#   The Lmod modulefile aliases "opencode" to this script. Users just run:
#   opencode. The sandbox is transparent — they never interact with bwrap.
#
#   DEPLOYMENT: this repository is the SOURCE. What users execute is a copy at
#   /uufs/chpc.utah.edu/sys/installdir/r8/opencode/opencode_sndbx.sh, owned by
#   hpcapps. Editing the repo alone changes nothing for users — you must copy
#   the file there. egress_proxy.py MUST live in that same directory, because
#   CAMPUS_PROXY_BIN below defaults to a path relative to this script; split
#   them and every session dies at the pre-flight check. See RUNBOOK.md.
#
# SANDBOX POLICY (what the agent sees)
#   Read-write:
#     $PWD           — the user's current project directory (only)
#     /tmp           — ephemeral tmpfs, cleared on exit
#     ~/.local/share/opencode, ~/.local/state/opencode, ~/.config/opencode,
#     ~/.cache/opencode, ~/.opencode  — OpenCode's own state (see XDG_DIRS)
#   Read-only:
#     /usr /bin /lib /lib64 /etc      — core OS
#     /run                            — but see the /run section below: it is an
#                                       empty tmpfs with only its subdirectories
#                                       re-bound, NOT a plain read-only mount
#     /uufs/<cluster>/sys             — every cluster's software stack, so Slurm
#                                       clients and cluster-local tools resolve
#     $HOME                           — readable except the masks below
#     scratch dirs owned by the user, plus /scratch/general/vast/app-repo
#   Blocked (shadowed by empty tmpfs or /dev/null):
#     $HOME/.ssh, $HOME/.aws, $HOME/.config/gh, $HOME/.gnupg, $HOME/.netrc
#     plus credential-ish files in the project root — see DANGEROUS_FILES
#   Network (sandbox has no interface but loopback — --unshare-net):
#     vLLM inference      — socat tunnel to nimbus:44242
#     MCP docs server     — socat tunnel to nimbus:8000 (OPENCODE_MCP_TUNNEL=0)
#     Slurm controller    — socat tunnel, host discovered at launch
#                           (OPENCODE_SLURM_TUNNEL=0). SEE THE SECURITY NOTE at
#                           the tunnel itself: a submitted job runs OUTSIDE this
#                           sandbox, so this is a deliberate containment escape.
#     Campus HTTP(S)      — CIDR-restricted egress proxy (public U of U ranges)
#   Namespace isolation:
#     --unshare-pid  — agent cannot see or signal host processes
#     --unshare-user — unprivileged user namespace (no root)
#     --unshare-net  — no network interface but loopback
#     --new-session  — new session ID, prevents signal leakage
#     --die-with-parent — sandbox exits when the parent shell exits (no orphans)
#
#   NOT enforced here: whether the user enters the sandbox at all. The module
#   puts the real binary on PATH and aliases "opencode" to this script, and
#   aliases do not exist in non-interactive shells — so `bash -c opencode`, a
#   script, or an sbatch job step runs the agent unsandboxed. The mounts below
#   are kernel-enforced; the decision to use them is not.
#
# -----------------------------------------------------------------------------
# MAINTAINER ORIENTATION — bwrap in five minutes
# -----------------------------------------------------------------------------
#   If you have never used bubblewrap, read this before changing anything.
#
#   1. bwrap builds a new mount namespace from NOTHING. The sandbox starts with
#      an empty filesystem; every path the agent can see exists because a line
#      in BWRAP_ARGS put it there. There is no "inherit the host and subtract" —
#      it is "start empty and add". A path you did not mention does not exist.
#
#   2. ARGUMENTS ARE APPLIED IN ORDER, and a later one shadows an earlier one.
#      This is the single biggest source of bugs. `--ro-bind /etc /etc` followed
#      by `--ro-bind myhosts /etc/hosts` works; the reverse silently loses the
#      hosts file. See the ordering contract at BWRAP_ARGS.
#
#   3. The four primitives you will actually use:
#        --ro-bind SRC DST      expose SRC at DST, read-only
#        --bind    SRC DST      expose SRC at DST, read-write
#        --ro-bind-try SRC DST  same as --ro-bind, but do not abort if SRC is
#                               missing. Use for anything cluster- or
#                               node-dependent.
#        --tmpfs   DST          mount an empty writable tmpfs at DST. This is
#                               how you MASK a directory: the host content is
#                               untouched but invisible.
#      To mask a single FILE, bind /dev/null over it: `--ro-bind /dev/null F`.
#      Reads return EOF, writes fail EROFS.
#
#   4. Masking requires the target to already exist. bwrap must open() the
#      destination, so every mask in this file is guarded by a -f or -d test.
#
#   5. You CANNOT bind over a Unix socket. open() on a socket returns ENXIO and
#      that aborts the ENTIRE sandbox, not just that mount. This is why /run is
#      handled the way it is — see the /run section.
#
#   6. --unshare-user maps only your own uid/gid. Supplementary groups appear as
#      "nobody" inside, and name lookups need the sssd socket (bound below).
#
#   To see what the agent actually sees, run a shell instead of the agent:
#      cd ~/some-project && OPENCODE_BIN=/bin/bash opencode_sndbx.sh
#   Expect a "no job control" warning — --new-session means no controlling
#   terminal. That is normal, not a broken sandbox.
#
# -----------------------------------------------------------------------------
# HOW TO CHANGE THIS SANDBOX — cookbook
# -----------------------------------------------------------------------------
#   Each recipe names the ONE place to edit. Verify every change by running the
#   shell-instead-of-agent trick above and inspecting from inside.
#
#   (a) EXPOSE A NEW READ-ONLY PATH (a data dir, a software tree)
#       If it is a shared path everyone should see: add it to SHARED_REPOS.
#       If it is under a scratch root and should only appear when the user owns
#       it: the loop over the scratch roots already handles that — add the root.
#       Anything else: add a `--ro-bind-try SRC SRC` line to BWRAP_ARGS, placed
#       before the WORKDIR bind. Prefer -try so a missing path is not fatal on
#       nodes that lack it.
#
#   (b) MAKE A PATH WRITABLE
#       Only if OpenCode itself needs to persist state there: add it to
#       XDG_DIRS. Two consequences, both easy to miss: the entry is created on
#       the HOST with mkdir -p before launch, and it grants the agent write
#       access for the whole session. Do not use this for user data.
#
#   (c) MASK A CREDENTIAL FILE OR DIRECTORY
#       In $HOME: add a directory to SENSITIVE_DIRS. For a single file, copy the
#       ~/.netrc pattern just below that loop (`--ro-bind /dev/null`).
#       In the project directory: add to DANGEROUS_FILES or DANGEROUS_DIRS.
#       Remember masks only apply to paths that exist at launch, and only at the
#       project root — a nested src/.env is NOT masked.
#
#   (d) ADD A NETWORK TUNNEL to another service
#       FIVE edits, none of them adjacent. Miss one and it fails silently or
#       leaks a helper process past the session:
#         1. Declare <NAME>_SOCK, HOST_SOCAT_<NAME>_PID="" and
#            SANDBOX_<NAME>_CMD="" in the variable block BEFORE the trap is
#            installed — the trap must be able to see them even if we die early.
#         2. Start the host side:  socat UNIX-LISTEN:"$SOCK",fork TCP:host:port &
#            capture $!, then disown.
#         3. Set SANDBOX_<NAME>_CMD="socat TCP-LISTEN:<port>,bind=127.0.0.1,fork
#            UNIX-CLIENT:$SOCK & "   <-- the trailing "& " is REQUIRED; these
#            strings are concatenated with no separator before exec.
#         4. Splice ${SANDBOX_<NAME>_CMD} into SANDBOX_INIT_CMD.
#         5. Add pkill -P + kill lines to cleanup_sandbox_helpers.
#       Plus: if the service is reached by NAME, add a 127.0.0.1 entry to the
#       generated hosts file AND add the name to NO_PROXY_VALUE so the campus
#       proxy does not intercept it. If you used a new mktemp dir, bind it via
#       DYNAMIC_SOCKET_ARGS and rm -rf it in cleanup.
#
#   (e) FORWARD A NEW ENVIRONMENT VARIABLE
#       --clearenv wipes everything, so add an explicit --setenv line in
#       BWRAP_ARGS after --clearenv. Anything named OPENCODE_* is forwarded
#       automatically UNLESS its name contains TOKEN/KEY/SECRET/PASSWORD/
#       PASSWD/CREDENTIAL/AUTH — that filter is why an API key cannot currently
#       be handed to the agent this way.
#
#   (f) STOP EXPOSING SOMETHING
#       Delete its line, then verify from inside the sandbox that it is gone.
#       Removing a mount can break things far away: dropping the per-cluster
#       /uufs/<cluster>/sys trees resurrects "sbatch: command not found",
#       because PATH is forwarded verbatim and would point at a directory that
#       no longer exists inside.
#
# NOTES FOR ADMINS
#   1. OPENCODE_BIN (from the Lmod module) selects the real binary; the
#      discovery fallbacks below are only for running this script by hand.
#   2. CHPC_SPACK_ROOT overrides the site software root.
#   3. bwrap and socat must be available on compute nodes: `bwrap --version`.
#      NOTE: the unprivileged-userns pre-flight below is ADVISORY ONLY —
#      kernel.unprivileged_userns_clone does not exist on this kernel and the
#      check defaults to "enabled" when the sysctl is missing. The real test is
#      `unshare -Ur true` or `bwrap --ro-bind / / true`.
#   4. Slurm-dependent behaviour cannot be tested on nimbus, which has no Slurm
#      client tools. Use a cluster login node for those tests.
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration — Override via environment variables from the Lmod modulefile
# =============================================================================

# Absolute path to the real OpenCode binary.
# If OPENCODE_BIN is already set, use it. Otherwise, dynamically find the active
# version from PATH (prepended by Lmod), or fallback to the latest version on disk.
if [[ -z "${OPENCODE_BIN:-}" ]]; then
    # 1. Parse PATH for the Lmod-prepended opencode bin directory
    IFS=':' read -ra ADDR <<< "$PATH"
    for p in "${ADDR[@]}"; do
        if [[ "$p" =~ ^/uufs/chpc.utah.edu/sys/installdir/r8/opencode/[^/]+/bin$ ]]; then
            if [[ -f "$p/opencode" ]]; then
                OPENCODE_BIN="$p/opencode"
                break
            fi
        fi
    done
    # 2. Fallback: discover the latest version installed on disk
    if [[ -z "${OPENCODE_BIN:-}" ]]; then
        OPENCODE_BIN=$(ls -vd /uufs/chpc.utah.edu/sys/installdir/r8/opencode/*/bin/opencode 2>/dev/null | tail -n1 || true)
    fi
    # 3. Last resort hardcoded fallback to current default
    if [[ -z "${OPENCODE_BIN:-}" ]]; then
        OPENCODE_BIN="/uufs/chpc.utah.edu/sys/installdir/r8/opencode/1.2.15/bin/opencode"
    fi
fi
OPENCODE_REAL_BIN="${OPENCODE_BIN}"


# CHPC-specific filesystem path exposed into the sandbox (read-only)
CHPC_SYS_ROOT="${CHPC_SPACK_ROOT:-/uufs/chpc.utah.edu/sys}"

# The vLLM proxy endpoint (set by Lmod, or fall through to the default)
OPENCODE_API_BASE="${OPENCODE_API_URL:-http://nimbus.chpc.utah.edu:44242/v1}"

# Campus egress proxy. The sandbox remains network-isolated; this helper runs
# outside bwrap and only connects to destinations in the configured campus CIDRs.
WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAMPUS_PROXY_BIN="${OPENCODE_CAMPUS_PROXY_BIN:-${WRAPPER_DIR}/egress_proxy.py}"
CAMPUS_PROXY_PORT="${OPENCODE_CAMPUS_PROXY_PORT:-44244}"
CAMPUS_PROXY_LOG="${OPENCODE_CAMPUS_PROXY_LOG:-${HOME}/.local/state/opencode/campus-proxy.log}"
case "${OPENCODE_CAMPUS_PROXY:-1}" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
        CAMPUS_PROXY_ENABLED=0
        ;;
    *)
        CAMPUS_PROXY_ENABLED=1
        ;;
esac

# The project directory the agent is allowed to write to.
# Default: wherever the user was standing when they ran "opencode".
WORKDIR="${PWD}"
WORKDIR_REAL="$(cd "${WORKDIR}" && pwd -P)"
HOME_REAL="$(cd "${HOME}" && pwd -P)"

# The project bind mount is intentionally read-write. Refuse launch locations
# that would make all of $HOME writable or shadow the credential masks below.
if [[ "${WORKDIR_REAL}" == "${HOME_REAL}" ]]; then
    echo "" >&2
    echo "  ERROR: Refusing to run OpenCode with WORKDIR set to HOME." >&2
    echo "         cd into a project subdirectory before running opencode." >&2
    echo "" >&2
    exit 1
fi

if [[ "${WORKDIR_REAL}" == "/" ]]; then
    echo "" >&2
    echo "  ERROR: Refusing to run OpenCode from the filesystem root." >&2
    echo "         cd into a specific project directory before running opencode." >&2
    echo "" >&2
    exit 1
fi

case "${HOME_REAL}/" in
    "${WORKDIR_REAL}/"*)
        echo "" >&2
        echo "  ERROR: Refusing to run OpenCode from a directory that contains HOME." >&2
        echo "         cd into a specific project directory before running opencode." >&2
        echo "" >&2
        exit 1
        ;;
esac

WORKDIR="${WORKDIR_REAL}"

# =============================================================================
# Pre-flight checks
# =============================================================================

# --- bwrap must be available -------------------------------------------------
if ! command -v bwrap &>/dev/null; then
    echo ""
    echo "  ERROR: bubblewrap (bwrap) is not available on this node." >&2
    echo "         OpenCode requires a sandbox and cannot start without it." >&2
    echo "         Please contact helpdesk@chpc.utah.edu" >&2
    echo ""
    exit 1
fi

# --- socat must be available -------------------------------------------------
if ! command -v socat &>/dev/null; then
    echo ""
    echo "  ERROR: socat is not available on this node." >&2
    echo "         OpenCode requires socat for network isolation." >&2
    echo "         Please contact helpdesk@chpc.utah.edu" >&2
    echo ""
    exit 1
fi

# --- Campus proxy helper must be available when enabled ----------------------
if [[ "${CAMPUS_PROXY_ENABLED}" == "1" ]]; then
    if ! command -v python3 &>/dev/null; then
        echo ""
        echo "  ERROR: python3 is not available on this node." >&2
        echo "         OpenCode requires python3 for the campus egress proxy." >&2
        echo "         Please contact helpdesk@chpc.utah.edu" >&2
        echo ""
        exit 1
    fi
    if [[ ! -r "${CAMPUS_PROXY_BIN}" ]]; then
        echo ""
        echo "  ERROR: campus proxy helper not found at: ${CAMPUS_PROXY_BIN}" >&2
        echo "         Set OPENCODE_CAMPUS_PROXY_BIN or contact helpdesk@chpc.utah.edu" >&2
        echo ""
        exit 1
    fi
fi

# --- The real binary must exist ----------------------------------------------
if [[ ! -x "${OPENCODE_REAL_BIN}" ]]; then
    echo ""
    echo "  ERROR: OpenCode binary not found at: ${OPENCODE_REAL_BIN}" >&2
    echo "         The module may be misconfigured. Contact helpdesk@chpc.utah.edu" >&2
    echo ""
    exit 1
fi

# --- Unprivileged user namespaces must be enabled ---------------------------
# (They always are on CHPC — Apptainer depends on this too — but let's check.)
_userns=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "1")
if [[ "${_userns}" == "0" ]]; then
    echo ""
    echo "  ERROR: Unprivileged user namespaces are disabled on this node." >&2
    echo "         (kernel.unprivileged_userns_clone = 0)" >&2
    echo "         bwrap sandboxing is not possible. Contact helpdesk@chpc.utah.edu" >&2
    echo ""
    exit 1
fi


# Files in the project root that should never be writable by the agent.
#
# These are masked with /dev/null, so the agent sees them as empty and cannot
# write them. Two limits worth knowing before you trust this list:
#   - Only the PROJECT ROOT is scanned. A nested src/.env is untouched.
#   - Only files that exist AT LAUNCH are masked. One the agent creates during
#     the session is a normal writable file.
# The list is not arbitrary; entries fall into four groups:
#   shell rc files (.bashrc … .profile, .aliases) and CHPC's module hooks
#     (custom.sh/.csh) — these execute on the user's next login, so a writable
#     one turns a sandboxed edit into unsandboxed code execution later;
#   tool config that redirects where code or credentials come from (.gitconfig,
#     .gitmodules, .npmrc, .yarnrc, .pnpmfile.cjs, .ripgreprc);
#   .mcp.json, which declares agent-reachable tool servers — writable, the agent
#     could grant itself new capabilities;
#   credential files (.netrc, .env*).
# To add one: append the basename here. To stop masking one: delete it and
# confirm from inside the sandbox that the file is really readable.
DANGEROUS_FILES=(
    .bashrc
    .bash_profile
    .tcshrc
    .zshrc
    .zprofile
    .profile
    .aliases
    .gitconfig
    .gitmodules
    .ripgreprc
    .mcp.json
    .npmrc
    .yarnrc
    .pnpmfile.cjs
    .netrc
    .env
    .env.local
    .env.production
    custom.sh
    custom.csh
)

# Directories in the project root that should never be writable.
#
# Masked with an empty --tmpfs rather than /dev/null, since the target is a
# directory. Same launch-time and project-root-only limits as DANGEROUS_FILES.
# The theme is "directories whose contents are executed or trusted by some other
# tool later": editor task/launch configs (.vscode, .idea), agent-definition
# directories (.claude/commands, .claude/agents), and git hooks. .git/config is
# handled separately just below — it is a file, and it is masked so the agent
# cannot rewrite a remote URL or point core.hooksPath somewhere it controls.
DANGEROUS_DIRS=(
    .vscode
    .idea
    .claude/commands
    .claude/agents
    .git/hooks
)

# Collect bwrap deny arguments dynamically
DYNAMIC_DENY_ARGS=()

for f in "${DANGEROUS_FILES[@]}"; do
    target="${WORKDIR}/${f}"
    if [[ -f "${target}" ]]; then
        DYNAMIC_DENY_ARGS+=(--ro-bind /dev/null "${target}")
    fi
done

for d in "${DANGEROUS_DIRS[@]}"; do
    target="${WORKDIR}/${d}"
    if [[ -d "${target}" ]]; then
        # Directories: mount a tmpfs over the path to make it appear as an empty directory
        DYNAMIC_DENY_ARGS+=(--tmpfs "${target}")
    elif [[ -f "${target}" ]]; then
        DYNAMIC_DENY_ARGS+=(--ro-bind /dev/null "${target}")
    fi
done

# Also block .git/config specifically (separate from .git/hooks)
# The agent may commit but must not be able to rewrite remote URLs or hooks.
git_config="${WORKDIR}/.git/config"
if [[ -f "${git_config}" ]]; then
    DYNAMIC_DENY_ARGS+=(--ro-bind /dev/null "${git_config}")
fi

# =============================================================================
# Build dynamic credential masking mounts — shadow sensitive folders in $HOME
# =============================================================================
# bwrap requires the mount points to exist on the parent read-only mount ($HOME)
# to mount things over them. If a folder (like ~/.aws) doesn't exist on the host,
# we don't need to mask it since the agent won't see it anyway. If it does exist,
# we overlay it with an empty tmpfs (for directories) or /dev/null (for files)
# so the agent sees it as empty/blank.
#
# $HOME itself is bound READ-ONLY, which is why a directory that does not exist
# needs no mask: the agent cannot create it. Only existing ones are shadowed.
#
# TO ADD A CREDENTIAL DIRECTORY: append a $HOME-relative path here. For a single
# FILE, copy the ~/.netrc pattern below instead — a file needs /dev/null, not a
# tmpfs. Candidates deliberately NOT masked today, because nothing at CHPC uses
# them yet: .kube, .docker/config.json, .git-credentials, .pypirc,
# .config/gcloud, .azure. Add them if that changes.
#
# Known gap: ~/.mychpc-access-token is NOT masked. It is a live portal bearer
# token, but mychpc authenticates with exactly that file, so masking it would
# break the command inside the sandbox. Left readable deliberately.
DYNAMIC_CRED_MASK_ARGS=()
SENSITIVE_DIRS=(
    .ssh
    .aws
    .config/gh
    .gnupg
)

for d in "${SENSITIVE_DIRS[@]}"; do
    target="${HOME}/${d}"
    if [[ -d "${target}" ]]; then
        DYNAMIC_CRED_MASK_ARGS+=(--tmpfs "${target}")
    fi
done

if [[ -f "${HOME}/.netrc" ]]; then
    DYNAMIC_CRED_MASK_ARGS+=(--ro-bind /dev/null "${HOME}/.netrc")
fi

# =============================================================================
# Build /run mounts — expose subdirectories, drop broadly-permissioned sockets
# =============================================================================
# /run must be visible so the CHPC software stack and core OS work as expected.
# But a --ro-bind only blocks writes to the mount; it does NOT block connect()
# to a Unix socket that already exists there. Some system services (e.g.
# gssproxy, Kerberos credential-cache managers, rpcbind) intentionally drop
# group- or world-writable sockets directly under /run (as opposed to a
# per-user /run/user/<uid> subdirectory) so any local process can request a
# credential for the invoking user. Left exposed, that would let the sandboxed
# agent authenticate as the user through a channel the --unshare-net /
# --unshare-pid isolation was never meant to permit.
#
# Those sockets cannot be masked individually: a bwrap bind-mount has to open()
# its destination, and open() on a Unix socket fails with ENXIO ("No such
# device or address"), which aborts the whole sandbox. Instead, mount an empty
# tmpfs at /run and re-bind only its subdirectories read-only. Top-level
# sockets and files then simply never appear inside the sandbox — no per-service
# names hardcoded, and nothing to update when a new daemon drops a socket there.
DYNAMIC_RUN_ARGS=(--tmpfs /run)
if [[ -d /run ]]; then
    while IFS= read -r -d '' rundir; do
        DYNAMIC_RUN_ARGS+=(--ro-bind-try "${rundir}" "${rundir}")
    done < <(find /run -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# =============================================================================
# Build dynamic per-cluster system tree mounts
# =============================================================================
# CHPC_SYS_ROOT (/uufs/chpc.utah.edu/sys) carries the site-wide software stack,
# but each cluster also has its own /uufs/<cluster>/sys tree holding
# cluster-local tooling — most importantly the Slurm client binaries and the
# libraries they link against, e.g. on granite:
#     /uufs/granite/sys/installdir/slurm/std/bin/sbatch
#     /uufs/granite/sys/installdir/slurm/<ver>/lib/slurm/libslurmfull.so
# PATH is forwarded into the sandbox verbatim, so without these trees bound the
# binaries are simply absent and users see "sbatch: command not found" even
# though the same command works fine outside the sandbox.
#
# Only the read-only "sys" software trees are exposed — never /uufs/<cluster>
# wholesale, which would also pull in other users' home and group directories.
DYNAMIC_SYS_ROOT_ARGS=()
for sys_root in /uufs/*/sys; do
    [[ -d "${sys_root}" ]] || continue
    [[ "${sys_root}" != "${CHPC_SYS_ROOT}" ]] || continue
    DYNAMIC_SYS_ROOT_ARGS+=(--ro-bind-try "${sys_root}" "${sys_root}")
done

# =============================================================================
# Build dynamic writable XDG state directories for OpenCode
# =============================================================================
# OpenCode needs to write logs, cache files, and SQLite databases to standard
# XDG directories (~/.local/share/opencode, ~/.config/opencode, ~/.cache/opencode).
# We ensure they exist on the host and bind-mount them read-write.
#
# THESE ARE THE ONLY WRITABLE PATHS OUTSIDE $WORKDIR AND /tmp. Adding an entry
# has two consequences that are easy to miss:
#   1. The mkdir -p below runs on the HOST, before the sandbox exists. Listing a
#      path here creates it in the user's real home directory.
#   2. It grants the agent write access there for the whole session. Only add
#      paths OpenCode itself must persist to — never user data.
# Load-bearing entry: .local/state/opencode is where CAMPUS_PROXY_LOG lives.
# Remove it and the campus egress proxy cannot open its log, which under set -e
# takes the whole launch down.
DYNAMIC_XDG_ARGS=()
XDG_DIRS=(
    .local/share/opencode
    .local/state/opencode
    .config/opencode
    .cache/opencode
    .opencode
)
for d in "${XDG_DIRS[@]}"; do
    mkdir -p "${HOME}/${d}"
    DYNAMIC_XDG_ARGS+=(--bind "${HOME}/${d}" "${HOME}/${d}")
done

# =============================================================================
# Build dynamic OpenCode environment passthrough
# =============================================================================
# The sandbox clears the host environment, but CHPC module/admin configuration may
# provide OPENCODE_* settings. Forward those while keeping the tunneled API URL
# authoritative inside the sandbox.
#
# compgen -e lists EXPORTED variables only, so a shell variable the module set
# without export will not appear here. Two filters apply:
#   - OPENCODE_API_URL is dropped, because the tunnel rewrites it below and a
#     later --setenv of the same name would win.
#   - Anything whose name contains TOKEN/KEY/SECRET/PASSWORD/PASSWD/CREDENTIAL/
#     AUTH is dropped, so a secret exported on the host never reaches the agent.
# That second filter is why there is currently no way to hand the proxy an API
# key through this channel — worth knowing before planning to enable proxy auth.
# Note the module also sets OPENTUI_FORCE_EXPLICIT_WIDTH, which does NOT match
# the OPENCODE_* glob and is therefore silently dropped by --clearenv; if it
# ever matters, it needs an explicit --setenv line.
DYNAMIC_OPENCODE_ENV_ARGS=()
while IFS= read -r name; do
    case "${name}" in
        OPENCODE_API_URL)
            continue
            ;;
    esac
    upper_name="${name^^}"
    case "${upper_name}" in
        *TOKEN*|*KEY*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*AUTH*)
            continue
            ;;
    esac
    DYNAMIC_OPENCODE_ENV_ARGS+=(--setenv "${name}" "${!name}")
done < <(compgen -e OPENCODE_ || true)

# =============================================================================
# Build dynamic scratch mounts — prevent intrusive reading of other users
# =============================================================================
# We intentionally do NOT --ro-bind scratch roots wholesale. If we did, the
# agent could list/read world-readable files belonging to other users. Instead,
# mount only scratch directories owned by the invoking user and specific shared
# repositories.
DYNAMIC_SCRATCH_ARGS=()

# Append one read-only scratch mount, skipping duplicates.
#
# !! INVARIANT — READ BEFORE EDITING !!
# The dedup loop walks DYNAMIC_SCRATCH_ARGS three elements at a time and reads
# index i+2 as the destination. That is only correct because EVERY entry this
# function appends is exactly three tokens: --ro-bind SRC DST. If you ever make
# it append a two-token flag (say a bare --ro-bind-try SRC, or any option
# without an argument), the stride silently desynchronises: dedup starts
# comparing sources against destinations, stops catching duplicates, and bwrap
# receives a mangled argument list. There is no error — it just misbehaves.
# Adding a different mount SHAPE means rewriting this loop, not extending it.
#
# The symlink guard is a security check, not tidiness: a symlinked scratch
# directory could point anywhere (another user's tree, /etc), and bwrap resolves
# the source path on the host, so binding it would expose the target.
add_scratch_mount() {
    local scratch_dir="$1"
    local existing_dest
    local i

    [[ -d "${scratch_dir}" ]] || return 0
    [[ ! -L "${scratch_dir}" ]] || return 0

    for ((i = 0; i < ${#DYNAMIC_SCRATCH_ARGS[@]}; i += 3)); do
        existing_dest="${DYNAMIC_SCRATCH_ARGS[$((i + 2))]}"
        if [[ "${existing_dest}" == "${scratch_dir}" ]]; then
            return 0
        fi
    done

    DYNAMIC_SCRATCH_ARGS+=(--ro-bind "${scratch_dir}" "${scratch_dir}")
}

# Same, but only if the invoking user owns the directory.
#
# -O is the gate that keeps this sandbox from exposing other users' scratch.
# Scratch directories are frequently world-readable, so ownership — not mode —
# is what decides. Anything routed through add_scratch_mount directly instead
# (see SHARED_REPOS) deliberately bypasses this check.
add_owned_scratch_mount() {
    local scratch_dir="$1"

    [[ -O "${scratch_dir}" ]] || return 0
    add_scratch_mount "${scratch_dir}"
}

# 1. User-owned scratch directories, including non-$USER directory names.
for scratch_base in /scratch/general/vast /scratch/general/nfs1 /scratch/local; do
    [[ -d "${scratch_base}" ]] || continue
    for scratch_dir in "${scratch_base}"/*; do
        add_owned_scratch_mount "${scratch_dir}"
    done
done

# 2. Job-local scratch, when running inside a SLURM allocation.
SLURM_JOB_ID_VALUE="${SLURM_JOB_ID:-${SLURM_JOBID:-}}"
if [[ -n "${SLURM_JOB_ID_VALUE}" ]]; then
    add_owned_scratch_mount "/scratch/local/${SLURM_JOB_ID_VALUE}/${USER}"
fi

# 3. Specific shared repositories.
#
# THIS IS THE HOOK for exposing a shared read-only path to every user — recipe
# (a) in the cookbook at the top of this file. Add the absolute path here.
#
# Note the deliberate asymmetry: these go through add_scratch_mount, NOT
# add_owned_scratch_mount, so they are exposed regardless of who owns them.
# That is the whole point — app-repo is hpcapps-owned and every user needs it —
# but it means an entry here is a conscious decision to show one path to
# everyone. Only list directories whose entire contents are safe for any user
# to read, and keep it specific: never a parent that sweeps in user data.
SHARED_REPOS=(
    /scratch/general/vast/app-repo
)

for repo in "${SHARED_REPOS[@]}"; do
    add_scratch_mount "${repo}"
done

# =============================================================================
# Network Isolation & Proxy Tunneling (deny raw outside traffic)
# =============================================================================
# We completely disable the sandbox's network (--unshare-net), leaving it with
# only a loopback interface. To let the agent reach approved services, we bind
# Unix sockets into the sandbox and bridge localhost ports to those sockets.
# vLLM and the MCP documentation server each get a dedicated tunnel; campus
# HTTP(S) egress goes through a CIDR-aware proxy that resolves and enforces
# destinations outside the sandbox.

# Parse the API host and port
API_HOST="nimbus.chpc.utah.edu"
API_PORT="44242"

# MCP documentation server (CHPC RAG assistant, read-only search/ask/get tools).
# It needs its own tunnel for the same reason vLLM does: the campus egress proxy
# only routes to public U of U CIDRs, and this service lives on the private
# 10.244/16 network. Set OPENCODE_MCP_TUNNEL=0 to disable the tunnel.
MCP_HOST="${OPENCODE_MCP_HOST:-nimbus.chpc.utah.edu}"
MCP_PORT="${OPENCODE_MCP_PORT:-8000}"
case "${OPENCODE_MCP_TUNNEL:-1}" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
        MCP_TUNNEL_ENABLED=0
        ;;
    *)
        MCP_TUNNEL_ENABLED=1
        ;;
esac

# Slurm controller tunnel.
#
# SECURITY NOTE: a job submitted from inside the sandbox runs on a compute node
# OUTSIDE the sandbox, as the invoking user, with none of the restrictions
# enforced here — writable $HOME, unmasked credential directories, unrestricted
# network. Enabling this tunnel therefore lets the agent execute arbitrary
# unsandboxed code by writing a job script and submitting it. It is on by
# default because job submission is the core HPC workflow, but the containment
# guarantees in the header apply only to the agent's *own* process tree, not to
# anything it launches through Slurm. Set OPENCODE_SLURM_TUNNEL=0 to disable.
case "${OPENCODE_SLURM_TUNNEL:-1}" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
        SLURM_TUNNEL_ENABLED=0
        ;;
    *)
        SLURM_TUNNEL_ENABLED=1
        ;;
esac

# Helper-process lifecycle state.
#
# EVERY variable the cleanup trap touches is declared here, empty, BEFORE the
# trap is installed below. That ordering is the contract: the trap can fire at
# any point after installation — including from the campus-proxy startup failure
# a few dozen lines down — and under `set -u` an undeclared name would make the
# trap itself die, leaking the very helpers it exists to reap.
#
# Adding a tunnel? Declare its socket path, its PID variable and its
# SANDBOX_*_CMD string in this block. See recipe (d) at the top of the file.
SOCKET_DIR=$(mktemp -d -t opencode-sock-XXXXXX)
AGENT_SOCK="${SOCKET_DIR}/proxy.sock"
MCP_SOCK="${SOCKET_DIR}/mcp.sock"
SLURM_SOCK="${SOCKET_DIR}/slurmctld.sock"
HOST_SOCAT_PID=""
HOST_SOCAT_MCP_PID=""
HOST_SOCAT_SLURM_PID=""
SANDBOX_MCP_CMD=""
SANDBOX_SLURM_CMD=""
SLURM_CTLD_HOSTS=()
SLURM_CTLD_PORT=""
SLURM_CTLD_ADDR=""
CAMPUS_SOCKET_DIR=""
CAMPUS_PROXY_SOCK=""
CAMPUS_PROXY_PID=""
CAMPUS_PROXY_URL=""
SANDBOX_CAMPUS_PROXY_CMD=""
HOSTS_DIR=""

# Reap every helper started outside the sandbox, then exit with the original code.
#
# Three details that look redundant and are not:
#   - `local status=$?` MUST be the first statement. It captures the real exit
#     code before any command in this function overwrites it; the final
#     `exit "${status}"` hands it back. Insert anything above it and the script
#     always reports success.
#   - `pkill -P <pid>` before `kill <pid>`: every listener runs socat with
#     ",fork", which spawns one CHILD per connection. Killing only the parent
#     orphans those children, leaving live sockets bridging campus services
#     after the user's session has ended. The campus proxy needs no pkill — it
#     is a Python process managing its own threads.
#   - `|| true` on each line: under `set -e` a kill of an already-dead process
#     would abort cleanup partway through, skipping the rest.
#
# Trapped on EXIT only. Bash still runs EXIT for ordinary interrupts, and
# --die-with-parent reaps the sandbox itself, so this covers the normal cases.
cleanup_sandbox_helpers() {
    local status=$?
    [[ -n "${HOST_SOCAT_PID:-}" ]] && pkill -P "${HOST_SOCAT_PID}" 2>/dev/null || true
    [[ -n "${HOST_SOCAT_PID:-}" ]] && kill "${HOST_SOCAT_PID}" 2>/dev/null || true
    [[ -n "${HOST_SOCAT_MCP_PID:-}" ]] && pkill -P "${HOST_SOCAT_MCP_PID}" 2>/dev/null || true
    [[ -n "${HOST_SOCAT_MCP_PID:-}" ]] && kill "${HOST_SOCAT_MCP_PID}" 2>/dev/null || true
    [[ -n "${HOST_SOCAT_SLURM_PID:-}" ]] && pkill -P "${HOST_SOCAT_SLURM_PID}" 2>/dev/null || true
    [[ -n "${HOST_SOCAT_SLURM_PID:-}" ]] && kill "${HOST_SOCAT_SLURM_PID}" 2>/dev/null || true
    [[ -n "${CAMPUS_PROXY_PID:-}" ]] && kill "${CAMPUS_PROXY_PID}" 2>/dev/null || true
    [[ -n "${SOCKET_DIR:-}" ]] && rm -rf "${SOCKET_DIR}"
    [[ -n "${HOSTS_DIR:-}" ]] && rm -rf "${HOSTS_DIR}"
    [[ -n "${CAMPUS_SOCKET_DIR:-}" ]] && rm -rf "${CAMPUS_SOCKET_DIR}"
    exit "${status}"
}
trap cleanup_sandbox_helpers EXIT

# 1. Start host-side proxy: Unix Socket -> vLLM server
socat UNIX-LISTEN:"${AGENT_SOCK}",fork TCP:${API_HOST}:${API_PORT} &
HOST_SOCAT_PID=$!
# disown: the cleanup trap kills these helpers on exit; without disown, bash
# reports each kill as "line N: <pid> Terminated ..." which reads like an error.
disown "${HOST_SOCAT_PID}" 2>/dev/null || true

# 1a. Start host-side proxy: Unix Socket -> MCP documentation server.
# The inner listener binds the same port inside the sandbox, and /etc/hosts
# below maps nimbus.chpc.utah.edu to 127.0.0.1, so the MCP server URL in
# opencode.json resolves to this tunnel with no client-side configuration.
if [[ "${MCP_TUNNEL_ENABLED}" == "1" ]]; then
    socat UNIX-LISTEN:"${MCP_SOCK}",fork TCP:${MCP_HOST}:${MCP_PORT} &
    HOST_SOCAT_MCP_PID=$!
    disown "${HOST_SOCAT_MCP_PID}" 2>/dev/null || true
    SANDBOX_MCP_CMD="socat TCP-LISTEN:${MCP_PORT},bind=127.0.0.1,fork UNIX-CLIENT:${MCP_SOCK} & "
fi

# 1c. Start host-side proxy: Unix Socket -> Slurm controller.
#
# Which controller to reach is discovered at launch time rather than hardcoded,
# so the same wrapper works on every CHPC cluster. `scontrol show config`
# reports the effective configuration wherever slurm.conf actually lives, which
# is more reliable than guessing the path; parsing slurm.conf directly is the
# fallback for when the controller is unreachable from the launch node.
discover_slurm_controller() {
    local src line key value host conf seen
    local -a sources=()

    if command -v scontrol &>/dev/null; then
        sources+=("scontrol")
    fi
    for conf in "${SLURM_CONF:-}" /etc/slurm/slurm.conf /etc/slurm-llnl/slurm.conf; do
        [[ -n "${conf}" && -r "${conf}" ]] && sources+=("${conf}")
    done

    for src in "${sources[@]+${sources[@]}}"; do
        while IFS= read -r line; do
            line="${line%%#*}"
            [[ "${line}" == *=* ]] || continue
            key="${line%%=*}"
            value="${line#*=}"
            key="${key//[[:space:]]/}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            [[ -n "${value}" ]] || continue
            case "${key,,}" in
                # SlurmctldHost[0], SlurmctldHost[1], or the legacy
                # ControlMachine/ControlAddr. Values may carry an explicit
                # address in parentheses, e.g. "granite-cs1(10.0.0.5)".
                slurmctldhost*|controlmachine|controladdr)
                    host="${value%%(*}"
                    [[ -n "${host}" ]] || continue
                    # Primary controller's numeric address, from
                    # "name(10.0.0.5)" or a bare ControlAddr=10.0.0.5.
                    if [[ -z "${SLURM_CTLD_ADDR}" ]]; then
                        if [[ "${value}" =~ \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) ]]; then
                            SLURM_CTLD_ADDR="${BASH_REMATCH[1]}"
                        elif [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            SLURM_CTLD_ADDR="${host}"
                        fi
                    fi
                    for seen in "${SLURM_CTLD_HOSTS[@]+${SLURM_CTLD_HOSTS[@]}}"; do
                        [[ "${seen}" == "${host}" ]] && continue 2
                    done
                    SLURM_CTLD_HOSTS+=("${host}")
                    ;;
                slurmctldport)
                    # May be given as a range ("6817-6818"); the first port is
                    # the one clients connect to.
                    [[ -z "${SLURM_CTLD_PORT}" ]] && SLURM_CTLD_PORT="${value%%-*}"
                    ;;
            esac
        done < <(
            if [[ "${src}" == "scontrol" ]]; then
                timeout 5 scontrol show config 2>/dev/null || true
            else
                cat "${src}" 2>/dev/null || true
            fi
        )
        [[ ${#SLURM_CTLD_HOSTS[@]} -gt 0 ]] && break
    done

    [[ -n "${SLURM_CTLD_PORT}" ]] || SLURM_CTLD_PORT=6817
}

if [[ "${SLURM_TUNNEL_ENABLED}" == "1" ]] && command -v sbatch &>/dev/null; then
    discover_slurm_controller
    if [[ ${#SLURM_CTLD_HOSTS[@]} -gt 0 ]]; then
        # Only the primary controller gets a relay. Backup controllers are still
        # mapped to 127.0.0.1 in the sandbox hosts file below so client-side
        # failover resolves, but it lands on this same tunnel.
        socat UNIX-LISTEN:"${SLURM_SOCK}",fork \
            TCP:"${SLURM_CTLD_HOSTS[0]}":"${SLURM_CTLD_PORT}" &
        HOST_SOCAT_SLURM_PID=$!
        disown "${HOST_SOCAT_SLURM_PID}" 2>/dev/null || true
        SANDBOX_SLURM_CMD="socat TCP-LISTEN:${SLURM_CTLD_PORT},bind=127.0.0.1,fork UNIX-CLIENT:${SLURM_SOCK} & "

        # CHPC's slurm.conf sets ControlAddr to an IP literal, so the client
        # never consults /etc/hosts. Worse, glibc's AI_ADDRCONFIG rejects every
        # IPv4 lookup when 127.0.0.1 is the only address present. Adding the
        # controller IP to the sandbox's lo fixes both: the lookup passes and
        # the address is local, so the inner socat can listen on it. The
        # address is added by NETNS_WRAP at launch (see the bwrap dispatch).
        if [[ -n "${SLURM_CTLD_ADDR}" ]]; then
            SANDBOX_SLURM_CMD="socat TCP-LISTEN:${SLURM_CTLD_PORT},bind=${SLURM_CTLD_ADDR},fork UNIX-CLIENT:${SLURM_SOCK} & "
        fi
    fi
fi

# 1b. Start host-side campus egress proxy: Unix Socket -> campus CIDRs only
DYNAMIC_SOCKET_ARGS=(--bind "${SOCKET_DIR}" "${SOCKET_DIR}")

if [[ "${CAMPUS_PROXY_ENABLED}" == "1" ]]; then
    CAMPUS_SOCKET_DIR=$(mktemp -d -t opencode-campus-proxy-XXXXXX)
    CAMPUS_PROXY_SOCK="${CAMPUS_SOCKET_DIR}/campus-proxy.sock"
    python3 "${CAMPUS_PROXY_BIN}" --unix-socket "${CAMPUS_PROXY_SOCK}" >>"${CAMPUS_PROXY_LOG}" 2>&1 &
    CAMPUS_PROXY_PID=$!
    disown "${CAMPUS_PROXY_PID}" 2>/dev/null || true

    for _ in $(seq 1 50); do
        if [[ -S "${CAMPUS_PROXY_SOCK}" ]]; then
            break
        fi
        if ! kill -0 "${CAMPUS_PROXY_PID}" 2>/dev/null; then
            echo ""
            echo "  ERROR: campus egress proxy exited during startup." >&2
            echo "         Check ${CAMPUS_PROXY_LOG}" >&2
            echo ""
            exit 1
        fi
        sleep 0.1
    done
    if [[ ! -S "${CAMPUS_PROXY_SOCK}" ]]; then
        echo ""
        echo "  ERROR: campus egress proxy did not create its Unix socket." >&2
        echo "         Check ${CAMPUS_PROXY_LOG}" >&2
        echo ""
        exit 1
    fi

    DYNAMIC_SOCKET_ARGS+=(--bind "${CAMPUS_SOCKET_DIR}" "${CAMPUS_SOCKET_DIR}")
    CAMPUS_PROXY_URL="http://127.0.0.1:${CAMPUS_PROXY_PORT}"
    SANDBOX_CAMPUS_PROXY_CMD="socat TCP-LISTEN:${CAMPUS_PROXY_PORT},bind=127.0.0.1,fork UNIX-CLIENT:${CAMPUS_PROXY_SOCK} & "
fi

# 2. Create custom hosts file to map nimbus.chpc.utah.edu to localhost inside sandbox
#
# --unshare-net leaves the sandbox with loopback and NO RESOLVER, so any name a
# client inside needs must appear in this file or the connection fails before it
# ever reaches socat. Mapping nimbus to 127.0.0.1 is what lets URLs baked into
# the site config — the MCP server URL in opencode.json, for one — resolve onto
# the loopback tunnels with zero client-side configuration.
#
# This file is bind-mounted over /etc/hosts in BWRAP_ARGS. It must be bound
# AFTER /etc itself, or the /etc mount shadows it.
HOSTS_DIR=$(mktemp -d -t opencode-hosts-XXXXXX)
CUSTOM_HOSTS="${HOSTS_DIR}/hosts"
cat <<EOF >"${CUSTOM_HOSTS}"
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
127.0.0.1   nimbus.chpc.utah.edu nimbus
EOF

# Point every Slurm controller name at the loopback tunnel. The sandbox has no
# resolver (--unshare-net leaves only lo), so any name the Slurm client needs
# must be present here or the connection fails before it reaches socat.
#
# Bare IP literals are skipped: a client configured with a numeric ControlAddr
# never consults /etc/hosts. CHPC's clusters do set one; that address is added
# to the sandbox's lo instead (see NETNS_WRAP).
for ctld_host in "${SLURM_CTLD_HOSTS[@]+${SLURM_CTLD_HOSTS[@]}}"; do
    if [[ "${ctld_host}" =~ ^[0-9.]+$ || "${ctld_host}" == *:* ]]; then
        continue
    fi
    if [[ "${ctld_host%%.*}" != "${ctld_host}" ]]; then
        printf '127.0.0.1   %s %s\n' "${ctld_host}" "${ctld_host%%.*}" >>"${CUSTOM_HOSTS}"
    else
        printf '127.0.0.1   %s\n' "${ctld_host}" >>"${CUSTOM_HOSTS}"
    fi
done

# We need to bind-mount the socket directory into the sandbox after /tmp exists.

# Overwrite OPENCODE_API_BASE to point to the localhost tunnel inside the sandbox
OPENCODE_API_BASE="http://127.0.0.1:${API_PORT}/v1"

DYNAMIC_CAMPUS_PROXY_ENV_ARGS=()
if [[ "${CAMPUS_PROXY_ENABLED}" == "1" ]]; then
    NO_PROXY_VALUE="127.0.0.1,::1,localhost,localhost.localdomain,nimbus.chpc.utah.edu,nimbus"
    DYNAMIC_CAMPUS_PROXY_ENV_ARGS+=(
        --setenv HTTP_PROXY  "${CAMPUS_PROXY_URL}"
        --setenv HTTPS_PROXY "${CAMPUS_PROXY_URL}"
        --setenv ALL_PROXY   "${CAMPUS_PROXY_URL}"
        --setenv http_proxy  "${CAMPUS_PROXY_URL}"
        --setenv https_proxy "${CAMPUS_PROXY_URL}"
        --setenv all_proxy   "${CAMPUS_PROXY_URL}"
        --setenv NO_PROXY    "${NO_PROXY_VALUE}"
        --setenv no_proxy    "${NO_PROXY_VALUE}"
    )
fi

# The sandbox init command runs the inner proxy, then execs OpenCode
SANDBOX_INIT_CMD="socat TCP-LISTEN:${API_PORT},bind=127.0.0.1,fork UNIX-CLIENT:${AGENT_SOCK} & ${SANDBOX_MCP_CMD}${SANDBOX_CAMPUS_PROXY_CMD}${SANDBOX_SLURM_CMD}exec \"\$@\""

# =============================================================================
# Launch OpenCode inside the bwrap sandbox
# =============================================================================
# Build the full argument list as a bash array so the dynamic deny args
# slot in cleanly without quoting issues.
#
# -----------------------------------------------------------------------------
# ORDERING CONTRACT — bwrap applies these IN ORDER and each one can shadow an
# earlier one. The sequence below is not stylistic; these dependencies are
# load-bearing, and breaking one usually fails SILENTLY rather than loudly.
#
#   /etc              before  /etc/hosts        else the tunnel hostname map is
#                                               lost and every tunnel breaks
#   --tmpfs /run      before  its subdir binds  (both inside DYNAMIC_RUN_ARGS)
#   --symlink /run /var/run   — creates /var implicitly. NEVER add a --tmpfs
#                               /var after it: that destroys munge auth and with
#                               it every Slurm client, with no obvious symptom
#   $HOME bind        before  cred masks        else the HOME bind re-exposes
#                                               ~/.ssh and friends
#   cred masks        before  XDG binds         an XDG path overlapping a masked
#                                               dir would win
#   $WORKDIR bind     before  deny args         else the writable project bind
#                                               re-exposes the masked dotfiles
#   --tmpfs /tmp      before  socket binds      SOCKET_DIR is a mktemp under
#                                               /tmp; a later tmpfs hides it and
#                                               every tunnel silently fails
#   --clearenv        before  every --setenv    else the variables are wiped
#   --                terminates options; "_" after it is the $0 placeholder for
#                     `bash -c`, so the real binary lands in $1
#
# Two more things that surprise people:
#   - The socket dirs use --bind (read-WRITE) on purpose: connect() to a Unix
#     socket needs write permission on the inode. --ro-bind there breaks them.
#   - "${ARR[@]+${ARR[@]}}" is not a typo. Under `set -u` a plain "${ARR[@]}" on
#     an EMPTY array is an unbound-variable error on older bash; the ${VAR+alt}
#     form expands to nothing instead. Each element still expands as a separate
#     array element, which is why splicing works at all.
# -----------------------------------------------------------------------------
BWRAP_ARGS=(
    # ── Core OS — read-only ────────────────────────────────────────────────
    --ro-bind   /usr                    /usr
    --ro-bind   /bin                    /bin
    --ro-bind   /lib                    /lib
    --ro-bind   /lib64                  /lib64
    --ro-bind   /etc                    /etc
    --ro-bind   "${CUSTOM_HOSTS}"           /etc/hosts
    # /run — empty tmpfs with only its subdirectories re-bound read-only, so
    # world-writable credential sockets sitting directly under /run (gssproxy,
    # KCM, rpcbind) are never reachable. See DYNAMIC_RUN_ARGS above.
    "${DYNAMIC_RUN_ARGS[@]+${DYNAMIC_RUN_ARGS[@]}}"
    # nsswitch.conf routes passwd/group lookups through "sss", which talks to
    # sssd over this socket. Without it, getpwuid()/getgrgid() inside the
    # sandbox can't resolve a name for the (identity-mapped) real UID/GID —
    # `id`/`groups` report "cannot find name for user/group ID N" even though
    # the numeric UID is correct, and anything that keys off the resolved
    # username (module/profile scripts, tools calling pwd.getpwuid(), etc.)
    # can misbehave. This is the NSS *lookup* socket only (not the pam/autofs
    # responders, which can authenticate) and is already world-connectable on
    # the host, so exposing it leaks no more than any unsandboxed `getent
    # passwd` already does.
    --ro-bind-try /var/lib/sss/pipes/nss /var/lib/sss/pipes/nss
    # On EL8 /var/run is a symlink to /run, and nothing else in this argument
    # list creates /var. Slurm's munge authentication plugin opens its socket by
    # the compiled-in /var/run/munge/munge.socket.2 path, so without this the
    # path does not exist inside the sandbox and every Slurm client fails to
    # authenticate — even with the controller tunnel up. The socket itself
    # arrives via the /run/munge directory re-bind in DYNAMIC_RUN_ARGS.
    --symlink   /run                    /var/run

    # ── CHPC software stack — read-only ─────────────────────────────────────
    # Gives the agent access to compilers, git, python, node, etc.
    # that are managed by CHPC's Spack/Lmod installation.
    --ro-bind   "${CHPC_SYS_ROOT}"          "${CHPC_SYS_ROOT}"
    # Per-cluster /uufs/<cluster>/sys trees (Slurm clients, cluster-local
    # modulefiles). See DYNAMIC_SYS_ROOT_ARGS above.
    "${DYNAMIC_SYS_ROOT_ARGS[@]+${DYNAMIC_SYS_ROOT_ARGS[@]}}"

    # ── Shared scratch — read-only ───────────────────────────────────────────
    # To prevent intrusive reading of other users' directories, we ONLY mount
    # the user's personal scratch space and specific shared repositories via
    # DYNAMIC_SCRATCH_ARGS below. We do NOT mount all of /scratch/general/vast.
    "${DYNAMIC_SCRATCH_ARGS[@]+${DYNAMIC_SCRATCH_ARGS[@]}}"

    # ── User home directory — read-only, with credential dirs blocked ────────
    --ro-bind   "${HOME}"                   "${HOME}"
    # Shadow sensitive credential directories dynamically (only if they exist on the host)
    "${DYNAMIC_CRED_MASK_ARGS[@]+${DYNAMIC_CRED_MASK_ARGS[@]}}"
    # Writable XDG state directories for OpenCode databases/logs
    "${DYNAMIC_XDG_ARGS[@]+${DYNAMIC_XDG_ARGS[@]}}"

    # ── Project directory — read-write ───────────────────────────────────────
    # THIS IS THE ONLY LOCATION THE AGENT CAN WRITE TO.
    # Users must cd into their project before running opencode.
    --bind      "${WORKDIR}"                "${WORKDIR}"

    # ── Runtime essentials ───────────────────────────────────────────────────
    --proc      /proc
    --dev       /dev
    --tmpfs     /tmp
    --tmpfs     /var/tmp
    "${DYNAMIC_SOCKET_ARGS[@]+${DYNAMIC_SOCKET_ARGS[@]}}"

    # ── Namespace isolation ───────────────────────────────────────────────────
    --unshare-pid
    --unshare-user
    --unshare-net
    --new-session
    --die-with-parent

    # ── Environment variables passed into the sandbox ─────────────────────────
    # --clearenv wipes EVERYTHING; the sandbox then gets exactly what is listed
    # below and nothing else. That is the point: a secret exported in the user's
    # shell never reaches the agent.
    #
    # TO FORWARD A NEW VARIABLE: add a --setenv line here (recipe (e) up top).
    # Two rules — it must come after --clearenv, and if the same name is set
    # twice the LAST one wins, which is how the rewritten OPENCODE_API_URL below
    # beats any value inherited from the host.
    #
    # PATH is forwarded verbatim, which is precisely why the per-cluster
    # /uufs/<cluster>/sys trees must be bound above: PATH will point at cluster
    # tool directories, and an unbound one simply does not exist inside.
    --clearenv
    --setenv    SANDSTONE_KEY  "${SANDSTONE_KEY:-}"
    --setenv    HOME            "${HOME}"
    --setenv    USER            "${USER}"
    --setenv    LOGNAME         "${USER}"
    --setenv    PATH            "${PATH}"
    --setenv    TERM            "${TERM:-xterm-256color}"
    --setenv    LANG            "${LANG:-en_US.UTF-8}"
    --setenv    SHELL           "${SHELL:-/bin/bash}"
    --setenv    MODULEPATH      "${MODULEPATH:-}"
    --setenv    LMOD_PKG        "${LMOD_PKG:-}"
    --setenv    OPENTUI_FORCE_EXPLICIT_WIDTH "${OPENTUI_FORCE_EXPLICIT_WIDTH:-false}"
    # above line needed to prevent the character interpretation issues on different terminals
    # Identifies which cluster the session is on (e.g. "granite.peaks"). CHPC
    # tooling reads it to target the right cluster — mychpc derives its default
    # --cluster from it — and --clearenv would otherwise drop it, silently
    # leaving those commands with no cluster context.
    --setenv    UUFSCELL        "${UUFSCELL:-}"
    --setenv    SLURM_JOB_ID    "${SLURM_JOB_ID_VALUE:-}"
    --setenv    SLURM_JOBID     "${SLURM_JOB_ID_VALUE:-}"
    --setenv    TMPDIR          /tmp
    # OpenCode provider/model config — pre-set by Lmod, no user action needed
    --setenv    OPENCODE_API_URL "${OPENCODE_API_BASE}"
    # Campus-only HTTP(S) egress for tools that honor proxy environment variables
    "${DYNAMIC_CAMPUS_PROXY_ENV_ARGS[@]+${DYNAMIC_CAMPUS_PROXY_ENV_ARGS[@]}}"
    "${DYNAMIC_OPENCODE_ENV_ARGS[@]+${DYNAMIC_OPENCODE_ENV_ARGS[@]}}"

    # ── Dynamic deny args (dangerous files found in WORKDIR) ──────────────────
    # Populated by the scan above; empty array = no extra args.
    "${DYNAMIC_DENY_ARGS[@]+${DYNAMIC_DENY_ARGS[@]}}"

    # ── Launch the real binary via the sandbox init wrapper ───────────────────
    -- /bin/bash -c "${SANDBOX_INIT_CMD}" _
    "${OPENCODE_REAL_BIN}"
    "$@"
)

# Check if bwrap supports --clearenv.
#
# CHPC nodes ship bubblewrap 0.4.0, which does NOT have --clearenv, so in
# practice the fallback branch is the one that runs here. Both branches produce
# the same environment: --clearenv wipes it inside bwrap, `env -i` wipes it
# before bwrap starts, and the --setenv lines repopulate it either way.
#
# Two latent hazards in this dispatch, documented rather than changed because
# the launch path deserves its own tested commit:
#   1. `set -o pipefail` is in effect. If grep -q exits on its first match while
#      bwrap is still writing, bwrap takes SIGPIPE and the pipeline reports 141,
#      so a bwrap that DOES support --clearenv can still be routed to the
#      fallback. Harmless today (the fallback is equivalent), but it means this
#      test does not actually measure what it appears to measure.
#   2. `env -i` clears PATH, so `env` must find bwrap via the default
#      /bin:/usr/bin. If bwrap ever moves to a module or Spack prefix, the
#      fallback stops working. `env -i "$(command -v bwrap)"` would be robust.
#
# NETNS_WRAP: when the Slurm controller has a numeric address, an outer bwrap
# owns the network namespace instead of the sandbox. It adds that address to lo
# (see the Slurm tunnel section), drops its caps, and execs the sandbox bwrap
# without --unshare-net. The address cannot be added from inside the sandbox:
# --dev makes bwrap 0.4.0 nest a second user namespace, and caps there do not
# apply to a netns owned by the first. For the same reason the agent cannot
# alter this netns either.
NETNS_WRAP=()
if [[ -n "${SLURM_CTLD_ADDR}" && -n "${SANDBOX_SLURM_CMD}" ]]; then
    NETNS_WRAP=(/usr/bin/bwrap --dev-bind / / --unshare-user --unshare-net
        --cap-add CAP_NET_ADMIN --die-with-parent
        /bin/bash -c "/usr/sbin/ip addr add ${SLURM_CTLD_ADDR}/32 dev lo && exec /usr/bin/setpriv --inh-caps=-all --ambient-caps=-all \"\$@\"" _)
    INNER_ARGS=()
    for arg in "${BWRAP_ARGS[@]}"; do
        [[ "$arg" != "--unshare-net" ]] && INNER_ARGS+=("$arg")
    done
    BWRAP_ARGS=("${INNER_ARGS[@]}")
fi

if bwrap --help | grep -q -- --clearenv; then
    "${NETNS_WRAP[@]+${NETNS_WRAP[@]}}" bwrap "${BWRAP_ARGS[@]}"
else
    # Fallback for older bubblewrap versions (e.g. 0.4.0 on CHPC nodes)
    # Remove --clearenv since it is not supported, and use env -i to clear the environment.
    FILTERED_ARGS=()
    for arg in "${BWRAP_ARGS[@]}"; do
        if [[ "$arg" != "--clearenv" ]]; then
            FILTERED_ARGS+=("$arg")
        fi
    done
    env -i "${NETNS_WRAP[@]+${NETNS_WRAP[@]}}" bwrap "${FILTERED_ARGS[@]}"
fi
