---
name: partition-selection
description: Use when writing or submitting any SLURM job script. Contains CHPC partition selection logic to maximize cluster utilization and minimize queue wait times.
---

# CHPC Partition Selection Guide

Always run `mychpc batch` before writing a job script to see the user's available
partitions, categories, and current idle percentages. Use the output to apply the
decision logic below. Copy `--partition`, `--qos`, and `--account` values exactly
as shown in `mychpc batch` output — do not guess or construct these values.

Cluster context reminder: partition choice and cluster query context are related
but not interchangeable. If the user submits or later inspects a job from a
different login environment, they may need explicit cluster selection such as
`sbatch -M CLUSTER ...`, `squeue -M CLUSTER -j JOBID`, or
`sacct -M CLUSTER -j JOBID ...`.

---

## CPU Job Decision Tree

### 1. Owner CPU partition available? → Use it
If OWNER section contains CPU entries (e.g. `gompert-grn`, `wolf-kp`):
- Choose the owner partition with the **highest idle CPU %**
- Owner partitions have highest priority and do not consume general allocation
- Always specify `--ntasks` and `--mem` explicitly for node sharing

### 2. No owner CPU partition → Use GENERAL
- For **small tests or jobs ≤ 8 hours**: use `notchpeak-shared-short`
- For **longer jobs**: choose the GENERAL CPU partition with highest idle %
  among notchpeak, kingspeak, lonepeak
- **Granite CPU requires allocation** — only use if `granite` appears in the
  user's GENERAL list
- Always specify `--ntasks` and `--mem` explicitly

### 3. No allocation → kingspeak or lonepeak only
If granite and notchpeak do not appear in GENERAL (no allocation):
- Use `kingspeak` or `lonepeak` (whichever has higher idle %)
- `notchpeak-shared-short` is still available without allocation
- Granite is accessible via `granite-freecycle` (PREEMPTABLE) if needed

### 4. GENERAL heavily loaded (all partitions < ~15% idle) → Consider PREEMPTABLE
- Use `notchpeak-freecycle`, `notchpeak-guest`, or `kingspeak-guest`
- To reduce preemption risk, target owner node groups with historically low
  utilization using Slurm constraints:
  - Check https://www.chpc.utah.edu/usage/constraints/#ownernodes for 2-week
    owner utilization history
  - Target low-use groups: `#SBATCH -C "group1|group2"` (OR logic)
  - Combine group and memory constraints: `#SBATCH -C "group1&m256"`
- Add `#SBATCH --requeue` if the job supports checkpointing so it restarts
  automatically if preempted
- Warn the user: preemptable jobs can be cancelled at any time when the node
  owner submits a job

---

## GPU Job Decision Tree

### 1. Owner GPU partition available (non-RAI)? → Use it
If OWNER section contains GPU entries that are not RAI:
- Use the owner GPU partition with the highest idle GPU %

### 2. RAI GPU available? → Use if owner GPU unavailable or 0% idle
- RAI GPU partition: `rai-gpu-grn` with `--account=rai`
- Use the `-short` QOS variant (`rai-gpu-grn-short`) for shorter jobs

### 3. No owner GPU → GENERAL GPU
Choose from `granite-gpu`, `notchpeak-gpu`, `kingspeak-gpu`, `lonepeak-gpu`
by highest idle GPU %:
- `granite-gpu` requires allocation
- `notchpeak-gpu`, `kingspeak-gpu`, `lonepeak-gpu` do **not** require allocation

### 4. GENERAL GPU heavily loaded → PREEMPTABLE GPU
- Use `granite-gpu-freecycle`, `notchpeak-gpu-guest`, or `kingspeak-gpu-guest`
- Same constraint-targeting and `--requeue` guidance as CPU preemptable jobs

---

## Node Sharing (Default Since January 2026)

Node sharing is enabled on all partitions. Always specify both:
```bash
#SBATCH --ntasks=N     # CPU cores needed
#SBATCH --mem=XG       # memory needed (e.g. 16G)
```

Default if `--mem` is omitted is 2G/core. Always set this explicitly for
memory-intensive jobs — over-requesting memory can charge allocation for
resources you didn't use (see allocation charging rules below).

### Exception: Requesting a whole node
For benchmarking or jobs that genuinely need exclusive node access:
```bash
#SBATCH --exclusive
#SBATCH --mem=0        # allocates all memory on the node
```

Only use this when necessary — it blocks node sharing and reduces cluster
utilization for other users.

---

## Allocation Charging Reminder

Usage is charged based on the **maximum** of fraction of cores, memory, or GPUs
used — not just what you actively consume. Key implications:
- Over-requesting memory on a GPU node can result in being charged for GPUs
  you didn't use
- Allocation is charged for resources *reserved*, not resources *used* — an
  idle interactive job still consumes allocation
- Request only what the job actually needs
