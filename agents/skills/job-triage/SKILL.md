---
name: job-triage
description: Use when a SLURM job has failed, was cancelled, won't start, or produced unexpected output on CHPC. Diagnoses the root cause from job logs and sacct output — covers OOM kills, walltime exceeded, invalid partition/account, missing modules, shared library errors, NFS path issues, and OOD/RStudio/Jupyter session failures. Distinct from slurm-utilization-audit, which tunes jobs that ran but were inefficient.
---

# CHPC Job Triage

Use this skill to diagnose why a SLURM job failed, was cancelled, or won't start. Always gather evidence first, then work through the diagnostic tree. If the root cause cannot be determined, escalate to the helpdesk.

---

## Step 1: Gather Evidence

Ask for the job ID if it is missing. Do not start diagnosing until you have at least the `sacct` output or the user has pasted an error message.

Before interpreting missing or incomplete Slurm output, verify that you are querying the correct cluster. If `sacct` returns only the header, a job appears to be missing, or `squeue`/`scontrol` cannot find the job, retry with explicit cluster selection first.

```bash
# Job state, exit code, and resource usage
sacct -j JOBID --format=JobID,JobName,State,ExitCode,Reason,Elapsed,ReqMem,MaxRSS,AllocCPUS,NodeList -X

# If the job may be on a different cluster, query it explicitly
sacct -M CLUSTER -j JOBID --format=JobID,JobName,State,ExitCode,Reason,Elapsed,ReqMem,MaxRSS,AllocCPUS,NodeList -X
squeue -M CLUSTER -j JOBID
scontrol -M CLUSTER show job JOBID

# Last 50 lines of job output (adjust filename as needed)
tail -50 slurm-JOBID.out

# Full job details — especially useful for pending jobs
scontrol show job JOBID
```

---

## Step 2: Diagnostic Tree

### A. Job never started

#### "Invalid account or account/partition combination"
- Run `mychpc batch` to show all valid partition/account/QOS combinations for this user
- Copy `--partition`, `--account`, and `--qos` values exactly from `mychpc batch` output — do not guess or construct them
- Verify the allocation is active for the current quarter

#### "Node count specification invalid" or `Reason=ReqNodeNotAvail`
- Single-job node limits: ~32 nodes (notchpeak), 24 (kingspeak), 106 (lonepeak)
- Check chpc.utah.edu news page for scheduled maintenance
- Suggest a different partition or waiting out maintenance

#### Job stuck in PENDING indefinitely
- If the job seems to be missing or not found, rule out a wrong-cluster query first by retrying the Step 1 commands with `-M CLUSTER`
- Check `scontrol show job JOBID` → look at the `Reason=` field
- `Resources` — normal queue wait, nothing wrong
- `QOSMaxJobsPerUser` — user has hit the concurrent job limit for that QOS; wait for other jobs to finish
- `ReqNodeNotAvail` — maintenance or reservation; check the news page

---

### B. Job ran but failed

#### OOM / Out of Memory (`State=OUT_OF_MEMORY`, `ExitCode=137`, or "Killed" in output)
- Confirm: check `sacct` output — is `MaxRSS` close to or exceeding `ReqMem`?
- Fix: increase `#SBATCH --mem=` (or `--mem-per-cpu=`)
- Starting estimate: `MaxRSS` × 1.5, rounded up to a round number
- For R jobs failing on project open: see `references/ood-rstudio.md` for `.RData` memory estimation

#### Walltime exceeded (`State=TIMEOUT`, "DUE TO TIME LIMIT" in output)
- Fix: increase `#SBATCH --time=`
- Maximum walltime is 72 hours; extensions beyond that require contacting CHPC staff
- If the application supports checkpointing, add `#SBATCH --requeue` so the job restarts automatically if preempted or timed out

#### Non-zero exit code with no obvious kill (`ExitCode=1`, `ExitCode=2`, etc.)
- The job output file is the primary diagnostic — read it carefully for the actual error message
- Common sub-cases:

**Missing module / "command not found"**
- Check `module avail <name>` — does the module exist on this cluster?
- Check that the module is loaded in the job script itself (`module load name/version`)
- Modules loaded in a login session do not carry over into batch jobs — they must be explicitly loaded in the script

**Shared library error** ("error while loading shared libraries" / "GLIBC_X.XX not found")
- Run `ldd <binary>` to list required libraries and identify what is missing
- Load the appropriate module or set `LD_LIBRARY_PATH`
- GLIBC version mismatch (program built on newer OS): find a Rocky Linux 8 / RHEL8 binary, rebuild from source on the cluster, or run via a Singularity/Apptainer container

**File or path not found**
- Verify all paths in the script are absolute — batch jobs may not run from `$HOME`
- Check whether scratch files were purged (60-day inactivity rule applies to `/scratch/general/vast` and `/scratch/general/nfs1`)
- NFS caching delay: if a file was just written by a previous step, add `sync` before reading it

---

### C. OOD / RStudio / Jupyter session failed

Load `references/ood-rstudio.md` for the full step-by-step diagnostic procedure.

Key symptoms and their likely causes:
| Symptom | Likely cause |
|---|---|
| Session never starts / job in "Failed" state | Startup error, bad module, scheduler issue |
| RStudio loads then goes blank when opening a project | OOM kill loading `.RData` |
| Session disappears after running for a while | Walltime limit hit |
| Blank screen immediately after connecting | RStudio Server crash at startup |
| OnDemand login fails entirely | `$HOME` over quota |

---

### D. Login node / Arbiter warning

- User received an Arbiter throttle warning or email
- Heavy computation must go through SLURM — not run directly on login nodes
- Help the user write a batch script (`sbatch`) or start an interactive session (`salloc -t 1:00:00 -N 1 -n 4`) for the work

---

## Step 3: Research External Documentation

When standard diagnostics don't yield a clear fix, search **specific software vendor documentation** for:

- **Application-specific error messages** (e.g., CUDA runtime errors, MPI failures, Python package conflicts, R package errors)
- **Version incompatibility issues** (e.g., "CUDA 12.x not compatible with X", "PyTorch requires CUDA Y")
- **Module or library errors** not covered in the diagnostic tree
- **Singularity/Apptainer container issues** (compatibility, version mismatches, feature flags)
- **Cryptic exit codes** that don't match standard SLURM patterns

**How to search:**
- Check the software project's official documentation or GitHub issues
- Look for CHPC-specific software documentation at `chpc.utah.edu`
- Search for the exact error message + software name + version
- **Tip:** If the software comes from a CHPC module, the `module show <name>` output often contains links to upstream GitHub repos or vendor documentation

If documentation search yields no results, proceed to Step 4 (Helpdesk Fallback).

---

## Step 4: Helpdesk Fallback

If the root cause cannot be determined from available evidence, or the fix requires CHPC staff intervention, direct the user to:

> **helpdesk@chpc.utah.edu**
> Include: job ID, cluster name, and the relevant error output. Staff typically respond within one business day.

**Ticket drafting:** Offer to help compose the ticket with a summary of:
- Job ID and cluster name
- What the user was trying to accomplish
- Diagnostic steps already attempted
- Relevant error messages or `sacct` output
- Any troubleshooting that has been tried

Always escalate to the helpdesk for:
- Account lockouts
- Allocation disputes or unexpected account/QOS changes
- Walltime extension requests beyond 72 hours
- Node reservation requests exceeding per-job limits
- Hardware failures or suspected node-level issues
- Parallelization and code optimization help
