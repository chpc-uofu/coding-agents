# Codex CLI — CHPC System Installation Notes

## Install Location

```
/uufs/chpc.utah.edu/sys/installdir/r8/codex/
├── bin/
│   └── codex              # wrapper script (see below)
├── etc/
│   ├── AGENTS.md          # symlink → /uufs/chpc.utah.edu/sys/etc/agents/AGENTS.md
│   ├── config.toml        # Codex configuration
│   └── skills/            # symlink → /uufs/chpc.utah.edu/sys/etc/agents/skills/
└── lib/
    └── node_modules/
        └── @openai/codex/ # actual Codex CLI binary
```

## Lua Module

```lua
load("nodejs/22.4.0")
local root = "/uufs/chpc.utah.edu/sys/installdir/r8/codex"
prepend_path("PATH", pathJoin(root, "bin"))
```

`CODEX_HOME` is intentionally NOT set in the Lua module — it is handled
by the wrapper script at runtime (see below). Do not add it back to the
Lua module.

## The `bin/codex` Wrapper Script

Codex requires write access to `CODEX_HOME` at startup for session state,
sqlite DB, logs, and memories. Since the system install directory is
read-only for users, pointing `CODEX_HOME` at `etc/` causes a
`Permission denied (os error 13)` error at launch — including in OOD
terminal sessions.

The wrapper script resolves this at runtime by:
1. Pointing `CODEX_HOME` and `CODEX_SQLITE_HOME` at the user's own `~/.codex/`
2. Symlinking the system-wide `AGENTS.md`, shared skill directories, and
   `config.toml` into that directory only when they do not conflict with
   user-owned files so updates propagate automatically without clobbering
   local state

```bash
#!/bin/bash
export CODEX_HOME="${HOME}/.codex"
export CODEX_SQLITE_HOME="${HOME}/.codex"
mkdir -p "${CODEX_HOME}/skills"

# Inject system-wide CHPC config via symlinks without overwriting
# user-owned files or directories.
SYSTEM_ETC="/uufs/chpc.utah.edu/sys/installdir/r8/codex/etc"
link_shared_file "${SYSTEM_ETC}/AGENTS.md" "${CODEX_HOME}/AGENTS.md"
link_shared_file "${SYSTEM_ETC}/config.toml" "${CODEX_HOME}/config.toml"

for skill_dir in "${SYSTEM_ETC}"/skills/*; do
  if [[ -d "${skill_dir}" ]]; then
    link_shared_skill "${skill_dir}"
  fi
done

exec /uufs/chpc.utah.edu/sys/installdir/r8/codex/lib/node_modules/@openai/codex/bin/codex.js "$@"
```

This means:
- Each user gets their own writable `~/.codex/` for state, auth tokens,
  logs, and memories
- System-wide CHPC config (`AGENTS.md`, skills, `config.toml`) is
  linked in only when the target path is absent or already points at the
  CHPC copy
- User-owned files and skill directories are preserved; the wrapper warns
  instead of overwriting them
- Updates to system files propagate to all users automatically on next launch
- Legacy broken skill trees like `~/.codex/skills/name/name -> shared`
  are repaired automatically when safe

**Important:** `bin/codex` is a shell script, not a symlink to the real
binary. Do not replace it with a symlink when upgrading — recreate the
wrapper and update the `exec` path to point at the new version's binary.

## System-Wide Config via Symlinks

`AGENTS.md` and `skills/` in `etc/` are symlinks into the shared
`/uufs/chpc.utah.edu/sys/etc/agents/` tree so Codex, OpenCode, and other
tools can share a single source of truth:

```bash
# AGENTS.md
ln -s /uufs/chpc.utah.edu/sys/etc/agents/AGENTS.md \
      /uufs/chpc.utah.edu/sys/installdir/r8/codex/etc/AGENTS.md

# skills directory
ln -s /uufs/chpc.utah.edu/sys/etc/agents/skills \
      /uufs/chpc.utah.edu/sys/installdir/r8/codex/etc/skills
```

To update AGENTS.md or skills for all tools, edit only the shared copies:
```
/uufs/chpc.utah.edu/sys/etc/agents/AGENTS.md
/uufs/chpc.utah.edu/sys/etc/agents/skills/
```

Changes are picked up by Codex users on their next launch.

## config.toml

Codex's configuration file. Sets defaults for all users.

```toml
model = "gpt-5.4"
approval_policy = "on-request"
```

- `model` — current recommended Codex-optimized model as of March 2026.
  Leave unset to always use OpenAI's current default, or pin to a specific
  version for consistency. `gpt-5.4-mini` is a faster, lower-cost alternative.
- `approval_policy` — `on-request` prompts the user before Codex runs
  shell commands. Appropriate for a shared HPC environment.

## Upgrading Codex

When installing a new version:

1. Install to a new versioned directory (do not overwrite in place)
2. Recreate `bin/codex` wrapper — update the `exec` path to point at
   the new binary
3. Update the Lua module version and `root` path
4. Create `etc/` with `config.toml` and symlinks to the shared
   `AGENTS.md` and `skills/`
5. Clean any stale runtime files from `etc/` if Codex wrote state there
   during testing (log/, memories/, tmp/, version.json, .personality_migration)
6. Test from SSH, salloc, and OOD terminal before switching default module

## Known Issues

### `ln: failed to create symbolic link ... partition-tree/partition-tree`
**Cause:** An older wrapper used `ln -sf` against a destination that might
already exist as a directory, creating a nested `name/name` symlink loop.
**Fix:** Use the current wrapper. It repairs the legacy one-entry case and
otherwise preserves the user's local skill directory with a warning.

### `Permission denied (os error 13)` on launch
**Cause:** `CODEX_HOME` is pointing at a read-only directory. Codex tries
to write state files there at startup and fails immediately.
**Fix:** Ensure the wrapper script is in place and `CODEX_HOME` is NOT
set in the Lua module. The wrapper handles it correctly at runtime.

### `WARNING: proceeding, even though we could not update PATH: Operation not permitted (os error 1)`
**Cause:** The RHEL8 kernel (4.18) on CHPC nodes predates Landlock support
(requires Linux 5.13+). Codex's Linux sandbox cannot fully initialize.
**Impact:** Non-fatal warning — Codex still runs correctly. Cannot be
fixed without a kernel upgrade.

### Update prompt (`✨⬆️ Update available!`)
**Cause:** Codex detects a newer npm version and prompts users to run
`npm install -g @openai/codex`.
**Fix:** Users should ignore this — updates are managed centrally by CHPC.
`CODEX_DISABLE_UPDATE_CHECK=1` may suppress this in future versions
(GitHub issue #4375, not yet resolved as of March 2026).
