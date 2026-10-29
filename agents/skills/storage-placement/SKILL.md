---
name: storage-placement
description: Use when writing job scripts, downloading data, staging input files, or deciding where to store results on CHPC. Guides selection of the correct filesystem (home, NFS scratch, VAST scratch, RAI scratch, local scratch, group/project, Pando archive, Redwood) based on file size, I/O pattern, retention needs, and data sensitivity.
---

# CHPC Storage Placement

Use this skill to recommend the correct CHPC filesystem for a given workload. Always gather evidence before recommending — run `mychpc storage` first, then work through the decision tree below.

---

## Step 1: Run `mychpc storage`

Always run `mychpc storage` before making recommendations. Use the output to:

- Warn if the user's personal `$HOME` quota is above ~80% (personal quota shown for `/home/hpc`)
- Flag any filesystem shown at ≥90% overall capacity cluster-wide
- Identify which group spaces the user has access to and whether they are healthy
- Note: no per-user scratch quota is shown — the 50 TB VAST cap is enforced at the filesystem level only

---

## Step 2: Decision Tree

Work through these checks in order:

### 1. Is the data PHI/PII/HIPAA?
→ **Redwood (Protected Environment) only.** Never copy sensitive data to general clusters.

### 2. Is it high-IOPS, single-node, fully ephemeral within one job?
→ `/scratch/local/$USER/$SLURM_JOB_ID`
- Node-local disk, 40–500 GB depending on node
- Fastest I/O on the cluster
- Purged automatically at job end — copy results out before the job finishes
- Files are inaccessible from other nodes — only use when all I/O is self-contained within the job

### 3. Everything else that touches scratch → default to VAST

→ `/scratch/general/vast`
- 1 PB total, 50 TB per-user cap, 60-day inactivity purge
- High-throughput parallel I/O — the standard choice for pipelines, large intermediates, and downloads
- Use `$SLURM_JOB_ID` in the path to keep jobs isolated

**Exception — RAI VAST:** If the user has an `rai` or `rai-gpu` partition visible in `mychpc batch` output,
they can use `/scratch/rai/vast1` instead.
- 1.8 PB, 50 TB/user + 100M inodes, no auto-delete
- Still not a permanent archive — copy important results to group space or Pando when done

**Fallback — NFS1:** Use `/scratch/general/nfs1` if `mychpc storage` shows `/scratch` overall at ≥90%.
- 595 TB, no per-user cap, same 60-day inactivity purge, moderate throughput

### 4. Scripts, configs, small final results to keep?
→ `$HOME`
- 50 GB soft quota (7-day grace), 75 GB hard block
- Never purged, but not backed up by default
- At hard limit: writes blocked, OnDemand and FastX sessions fail (SSH still works for cleanup)

### 5. Shared data within a research group?
→ `/uufs/chpc.utah.edu/common/home/<groupname>/`
- Available groups and their capacity shown in `mychpc storage` output
- **Not for job I/O** — NFS-mounted, same performance limitation as `$HOME`
- Good for shared scripts, reference datasets, and final results the group needs to access

### 6. Long-term archive of completed datasets?
→ Pando object storage (Globus endpoint, S3 API, rclone, Cyberduck)

---

## Step 3: Enforce Critical Rules

- **Never** run I/O-heavy jobs reading/writing `$HOME` or group space — NFS under parallel load is slow
- Always copy final results out of scratch **before** the 60-day inactivity clock expires
- `/scratch/local` files are gone at job end — always copy out before the job finishes
- `$HOME` at 75 GB hard limit → writes blocked, OnDemand and FastX sessions fail
- If `/scratch` overall capacity is ≥90%, warn the user and suggest NFS1 as a fallback

---

## Step 4: Standard Job Script Pattern

Include this scratch setup/teardown template when writing job scripts:

```bash
SCRATCHDIR=/scratch/general/vast/$USER/$SLURM_JOB_ID
mkdir -p $SCRATCHDIR

# Copy inputs in
cp -r $HOME/project/input $SCRATCHDIR/

# ... job commands using $SCRATCHDIR for all I/O ...

# Copy results back before job ends
cp -r $SCRATCHDIR/results $HOME/project/
```

For large data transfers into or out of CHPC, recommend Globus via the DTN nodes
(40 Gbps internal, 100 Gbps external) rather than `scp`.
