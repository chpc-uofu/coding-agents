# CHPC Coding Agents

Wrappers, configuration, and Lmod modulefiles that give users at the University of Utah Center for High Performance Computing (CHPC) access to AI coding agents on our clusters. Each agent loads with guardrails that limit network access, destructive commands, and access to credentials, plus CHPC-specific instructions and skills so the agent knows how to work with Slurm, modules, and our storage. Each agent handles system prompts, skills, and restrictions differently, so each has its own wrapper and config.

Coding agents are currently only allowed in our general environment, which is used for fairly open research computing. Users there can download and run their own binaries, so a determined user can get around any of these controls. The goal is safe defaults for well-meaning users: stop an agent from making common costly mistakes like deleting files, sending data off campus, or reading SSH keys, while keeping it useful for HPC work. It is also stated CHPC policy for users to use agents via our modules and not user-level installations.

Supported agents:

| Agent | Module | Model access |
|---|---|---|
| Claude Code | `claude` | Anthropic (user's own account) |
| Codex | `codex` | OpenAI (user's own account) |
| Codex, CHPC model | `codex_CHPC_local_model` | CHPC-hosted open model via vLLM |
| OpenCode | `opencode` | CHPC-hosted open model by default, others via `/connect` |
| Antigravity | `antigravity` | Google (user's own account) |

Users run `module load <agent>` and then the agent's normal command. The guardrails apply automatically. 

## How it works

Each agent is installed as two pieces:

- The vendor binary, renamed `<tool>-real` (not in this repo).
- A small wrapper script with the tool's normal name that adds CHPC flags, config, and sandboxing, then runs `<tool>-real`.

The modulefile puts the wrapper on `PATH`. Shared instructions (system prompt), skills, and per-tool settings live in one central directory (`agents/`) which is either pointed to in the wrapper or injected into the user's agent configuration directory with a seperate script..

## Repository layout

Each top-level folder mirrors a live location on the cluster. To deploy, copy files from the repo to the matching live path.

| Repo folder | Live location at CHPC | Contents |
|---|---|---|
| `agents/` | `/uufs/chpc.utah.edu/sys/etc/agents/` | `AGENTS.md`, skills, per-tool settings, MCP config |
| `installdir/<tool>/<version>/` | `/uufs/chpc.utah.edu/sys/installdir/r8/<tool>/<version>/` | Wrapper scripts and tool config |
| `module_files/<tool>/<version>.lua` | `/uufs/chpc.utah.edu/sys/modulefiles/CHPC-r8/Core/<tool>/<version>.lua` | Lmod modulefiles |

Key files:

- `agents/AGENTS.md`: system instructions shared by all agents (cluster rules, security rules, storage, CHPC-specific commands).
- `agents/skills/`: CHPC skills (`gpu-use`, `job-triage`, `partition-tree`, `slurm-utilization-audit`, `software-environments`, `storage-placement`).
- `agents/claude/settings.json`, `agents/claude/managed-mcp.json`: Claude Code permissions and the allowed MCP server.
- `agents/opencode.json`: allowed OpenCode providers, default model, and MCP server.
- `agents/codex_chpc_links.sh`, `agents/gemini_chpc_links.sh`: link `AGENTS.md` and skills into each user's `~/.codex` or `~/.gemini` without overwriting files the user created.
- `installdir/opencode/opencode_sndbx.sh`, `installdir/opencode/egress_proxy.py`: the OpenCode sandbox and its campus-only HTTP proxy.

## Guardrails

### Protected Environment block

Every modulefile refuses to load on Redwood, our protected environment (PE) cluster that hosts HIPAA/PHI data. The check matches `redwood` in the short hostname. Change it to match your own restricted hosts. A locally run inference service suitable for the PE is currently being developed at CHPC. When it is ready, a version of OpenCode will be made available in which it is only possible to connect to the local inference service.

### Claude Code

The wrapper runs `claude-real` with:

- `--settings agents/claude/settings.json`, which denies `WebFetch`, `WebSearch`, `curl`, `wget`, `rsync`, `scp`, and `rm`, and disables claude.ai connectors.
- `--strict-mcp-config --mcp-config managed-mcp.json`, so only the CHPC docs MCP server is available. `CLAUDE_CODE_SKIP_PLUGIN_MCP_SERVERS=1` stops plugins from adding their own.
- `--append-system-prompt-file` with the CHPC `CLAUDE.md`, and `--add-dir` so the CHPC skills are available by name.

These are permission rules inside Claude Code. They do not sandbox the process at the OS level.

### Codex

The wrapper:

- Pins config on the command line so it outranks the user's `~/.codex/config.toml` if it exists: web search off, code mode off, CHPC docs MCP server on.
- Runs Codex under `bwrap` with `curl`, `wget`, `rsync`, `scp`, `sftp`, `nc`, `ncat`, `telnet`, `rm`, `rmdir`, and `unlink` replaced by `/dev/null`, so the agent's shell cannot run them.
- Links the CHPC `AGENTS.md` and skills into `~/.codex`.

`codex_CHPC_local_model` uses the same approach but points Codex at the CHPC-hosted model (`model_providers.chpc-vllm` in the wrapper).

### OpenCode

OpenCode has the strongest isolation. `opencode_sndbx.sh` runs it inside a bubblewrap sandbox:

- **Filesystem:** read-write only to the current directory, a private `/tmp`, and OpenCode's own state dirs. The rest of `$HOME` and the software stack are read-only. `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config/gh`, and credential-like files in the project are hidden.
- **Network:** no network interface except loopback. Specific services are reached through local `socat` tunnels: the vLLM model server, the CHPC docs MCP server, and the Slurm controller. Other HTTP(S) traffic goes through `egress_proxy.py`, which only allows University of Utah public address ranges plus `sandbox.ai.utah.edu`.
- **Processes:** separate PID and user namespaces, so the agent cannot see or signal host processes. The sandbox exits with its parent shell.

Known gaps, documented in the script header:

- The Slurm tunnel is a deliberate escape. Jobs the agent submits run outside the sandbox.
- The module uses an alias to route `opencode` through the sandbox. Aliases do not apply in non-interactive shells, so `bash -c opencode` or a batch job runs it unsandboxed.

The modulefile sets two variables that load the CHPC instructions and skills:

- `OPENCODE_CONFIG` points to `agents/opencode.json`. Its `instructions` list adds `AGENTS.md` to the system prompt.
- `OPENCODE_CONFIG_DIR` points to `agents/`. OpenCode treats it as its config folder and scans `skills/<name>/SKILL.md` automatically.

OpenCode also loads skills from each user's `~/.claude/skills` and `~/.agents/skills`, so users see their own skills next to the CHPC ones.

`installdir/opencode/<version>/wrappers/opencode` also refuses to start if the current directory contains another user's uNID.

### Antigravity

The wrapper always passes `--sandbox`, which uses Linux namespaces to block outbound network access and restrict the filesystem to the workspace. It also links the CHPC instructions and skills into `~/.gemini/config/`, where Antigravity reads `AGENTS.md` as global rules and `skills/<name>/SKILL.md` as skills.

The wrapper is in `<version>/wrapper/` and the real binary is in `<version>/bin/`. The modulefile only puts `wrapper/` on `PATH`, so `antigravity-real` is not on `PATH` and users get the sandboxed wrapper by default.

### Shared instructions

`agents/AGENTS.md` (and `CLAUDE.md` for Claude Code) tells every agent the cluster rules: no heavy work on login nodes, no writes to `/sys`, no outbound network calls without approval, no credentials in output, confirm before deleting files, and load the partition selection skill before submitting jobs. These are instructions to the model. The hard limits come from the wrappers and sandbox above.

## Adapting this for your site

Search for these and replace them with your own values:

| What | Where |
|---|---|
| `/uufs/chpc.utah.edu/sys/...` install, config, and module paths | wrappers, modulefiles, linker scripts, `opencode_sndbx.sh` |
| `nimbus.chpc.utah.edu` (vLLM on port 44242, docs MCP on port 8000) | `agents/opencode.json`, `agents/claude/managed-mcp.json`, Codex wrappers, `opencode_sndbx.sh` |
| `sandbox.ai.utah.edu` | `agents/opencode.json`, `egress_proxy.py` |
| University of Utah CIDR ranges | `DEFAULT_ALLOWED_CIDRS` in `egress_proxy.py`, or set `CAMPUS_ALLOWED_CIDRS` |
| `redwood` hostname check | every modulefile |
| uNID pattern `u[0-9]{7}` | `installdir/opencode/<version>/wrappers/opencode` |
| `AGENTS.md`, `CLAUDE.md`, and skills content | `agents/` |

You also need `bwrap` (bubblewrap) with unprivileged user namespaces enabled on your login and compute nodes for the Codex and OpenCode sandboxes.

API keys are never stored in these files. They come from environment variables (for example `SANDSTONE_KEY`, `CHPC_CODER_API_KEY`) or each user's own login.

## Maintaining at CHPC

The live files are owned by `hpcapps`. This repo is the source, with the live copies copied to the correct path.

1. Edit and commit in this repo.
2. As `hpcapps`, copy changed files to the matching live path (see the layout table).
3. Every so often, check for edits made directly on the live copies and pull them back into the repo:

To add a new version of a tool: copy the previous version's folder and modulefile, update the version number and the hardcoded `DIR=` or `BWRAP=` path in the wrapper, and place the program binary as `<tool>-real` in the live `bin/` directory.
