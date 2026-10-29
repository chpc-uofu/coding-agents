# Sourced by the CHPC codex wrappers. Links the CHPC AGENTS.md and skills into
# the user's CODEX_HOME so every Codex module sees the same instructions.
#
# Rules:
#   - Never touch a file, directory, or symlink the user created.
#   - Symlinks that point into AGENTS_ROOT are ours: repair them if broken or
#     pointing at the wrong place, and remove them if the skill was retired.
#   - Print one summary line, only when something changed.

AGENTS_ROOT=${AGENTS_ROOT:-/uufs/chpc.utah.edu/sys/etc/agents}
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_DIR/skills"

chpc_link_setup() {
  local changed=0 src dst name

  if ! mkdir -p "$SKILLS_DIR" 2>/dev/null || [[ ! -w "$SKILLS_DIR" ]]; then
    echo "CHPC: $SKILLS_DIR is not writable; skipping AGENTS.md/skills setup" >&2
    return 0
  fi

  # Is $1 a symlink that belongs to CHPC (points somewhere under AGENTS_ROOT)?
  chpc_owned() { [[ -L "$1" && "$(readlink "$1")" == "$AGENTS_ROOT"/* ]]; }

  # Link src -> dst unless the user has something there.
  link_one() {
    src=$1; dst=$2
    if chpc_owned "$dst"; then
      [[ "$(readlink "$dst")" == "$src" ]] && return 0   # already correct
      rm -f "$dst"                                        # ours, but stale
    elif [[ -e "$dst" || -L "$dst" ]]; then
      return 0                                            # user-owned, leave it
    fi
    ln -s "$src" "$dst" 2>/dev/null && changed=$((changed + 1))
  }

  link_one "$AGENTS_ROOT/AGENTS.md" "$CODEX_DIR/AGENTS.md"

  # Every directory in AGENTS_ROOT/skills is linked; keep that directory tidy.
  for src in "$AGENTS_ROOT"/skills/*/; do
    src=${src%/}
    link_one "$src" "$SKILLS_DIR/$(basename "$src")"
  done

  # Drop our links for skills that no longer exist in AGENTS_ROOT.
  for dst in "$SKILLS_DIR"/*; do
    chpc_owned "$dst" && [[ ! -e "$dst" ]] && rm -f "$dst" && changed=$((changed + 1))
  done

  if (( changed > 0 )); then
    echo "CHPC: updated $changed AGENTS.md/skill link(s) in $CODEX_DIR (shared CHPC copies)" >&2
  fi
  return 0
}

chpc_link_setup
