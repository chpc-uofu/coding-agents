# Troubleshooting Failed OOD RStudio Jobs on CHPC

A step-by-step guide for diagnosing why a user's Open OnDemand RStudio job failed or produced a blank screen.

---

## Symptom Patterns

| Symptom | Likely Cause |
|---|---|
| RStudio session never starts / job in "Failed" state | Startup error, bad module, scheduler issue |
| RStudio loads but goes blank when opening a project | R session OOM-killed loading `.RData` |
| Job disappears after running for a while | Walltime limit hit |
| Blank screen immediately after connecting | RStudio Server crash at startup |

---

## Step 1: Find the Most Recent Job Directory

OOD stores job output under the user's home directory:

```
~/.../ondemand/data/sys/dashboard/batch_connect/sys/rstudio_server_app/output/
```

Full path pattern:
```
/uufs/chpc.utah.edu/common/home/<username>/ondemand/data/sys/dashboard/batch_connect/sys/rstudio_server_app/output/
```

List jobs sorted by time to find the most recent:
```bash
ls -lt /uufs/chpc.utah.edu/common/home/<username>/ondemand/data/sys/dashboard/batch_connect/sys/rstudio_server_app/output/
```

Each subdirectory (UUID-named) is one job. The top one is the most recent.

---

## Step 2: Read the Key Log Files

Inside the job directory, the two most important files are:

### `output.log`
The main job log. Look for:
- `RStudio Server listening on port XXXXX` → job started OK
- `CANCELLED ... DUE TO TIME LIMIT` → walltime exceeded
- `oom_kill event` → Out of Memory kill
- `sed: can't read` or `find: No such file or directory` → minor warnings from session cleanup, usually harmless

### `rsession.log`
The R session log. If it only contains:
```
Launching rsession...
Launching rsession...
```
...and nothing else, the R session is crashing immediately (often OOM when loading workspace).

---

## Step 3: Check How Much Memory Was Requested

In `output.log`, grep for:
```
SLURM_MEM_PER_CPU
SLURM_JOB_CPUS_PER_NODE
```

Total memory = `SLURM_MEM_PER_CPU` × `SLURM_JOB_CPUS_PER_NODE`

Or check `user_defined_context.json` in the job directory for the original form values.

---

## Step 4: Look for a Large `.RData` File

If the symptom is **blank screen when opening a project**, check for a large `.RData` in the user's project directory.

RStudio automatically loads `.RData` when opening a project. A large workspace will OOM-kill the session immediately.

Find `.RData` files:
```bash
find /uufs/chpc.utah.edu/common/home/<username>/ -maxdepth 6 -name ".RData" 2>/dev/null
```

Check the size:
```bash
ls -lh /path/to/project/.RData
```

### Memory Estimation

`.RData` files are gzip-compressed. In-memory size is typically **3–5x the file size on disk**.

| `.RData` on disk | Estimated in-memory |
|---|---|
| 500 MB | ~1.5–2.5 GB |
| 1 GB | ~3–5 GB |
| 1.5 GB | ~5–8 GB |
| 2 GB | ~6–10 GB |

**Rule of thumb:** double the estimated in-memory size to leave room for RStudio overhead and actual analysis work.

---

## Step 5: Recommend a Fix

### Fix A — Request More Memory (quick fix)
Tell the user to increase memory when launching the OOD RStudio job. A 1.5 GB `.RData` file → recommend **at least 16 GB**.

In the OOD RStudio form, the memory field is `memtask` (in MB). Make sure `memtask_checkbox` is enabled.

### Fix B — Remove or Rename the `.RData` (better long-term fix)
Rename the file so RStudio doesn't auto-load it:
```bash
mv /path/to/project/.RData /path/to/project/.RData.bak
```

The user can then manually load specific objects with `readRDS()` / `load()` rather than saving their entire environment. This is better practice for large analyses.

---

## Common Pitfalls

- **Default memory is very low** (2 GB with 1 CPU = 2 GB total). This is not enough for most bioinformatics R workflows.
- **`.rstudio` directory missing** is normal if the user has never run a session that completed cleanly — not a bug.
- **`sed: can't read` warnings** in `output.log` are from session cleanup scripts trying to find a previous session state. Harmless if RStudio still starts.
- **Two OOM + walltime in the same job** — OOM kill can happen mid-session without immediately terminating the SLURM job; the job may limp along until walltime.

---

## Quick Reference: File Locations

| File | Purpose |
|---|---|
| `output.log` | Main job log — SLURM errors, OOM, startup |
| `rsession.log` | R session log — session crashes |
| `user_defined_context.json` | Form values the user submitted |
| `job_script_options.json` | SLURM job options |
| `connection.yml` | Port/host info for the session |
| `~/.rstudio/` | RStudio user state (may not exist) |
| `~/Projects/**/.RData` | Saved R workspaces (check size!) |
