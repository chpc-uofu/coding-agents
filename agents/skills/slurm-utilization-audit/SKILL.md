---
name: slurm-utilization-audit
description: Audit CPU and GPU efficiency for CHPC SLURM jobs and turn utilization evidence into concrete changes to batch scripts and runtime parameters. Use when Codex needs to explain poor SLURM job efficiency, inspect CPU or GPU usage for a job ID, tune directives such as --nodes/--ntasks/--cpus-per-task/--gres/--mem/--time, or recommend application settings such as threads, workers, MPI ranks, batch size, and data-loading concurrency.
---

# SLURM Utilization Audit

Use this skill to convert CHPC accounting data into actionable tuning advice. Fetch job utilization data with `sacct` first, then use `sstat` when available, and only make optimization recommendations after reviewing that evidence. Recommend changes to both SLURM directives and application runtime settings.

## Collect Evidence

Ask for the job ID if it is missing.

Do not start suggesting optimizations until you have looked up the job's accounting data with `sacct` or the user has provided equivalent utilization evidence.

Collect a compact evidence bundle:

```bash
sacct -j JOBID --parsable2 --units=M \
  --format=JobIDRaw,JobName,State,ElapsedRaw,AllocCPUS,AllocTRES,ReqMem,MaxRSS,TotalCPU,CPUTimeRAW,TRESUsageInAve,TRESUsageInTot

sstat -j JOBID.batch --parsable2 --units=M \
  --format=JobID,AveCPU,AveRSS,MaxRSS,TRESUsageInAve,TRESUsageInMax
```

CHPC cluster hint:
- If `sacct` returns only the header, appears to miss a completed job, or `squeue`/`scontrol` cannot find the job, verify that you are querying the correct cluster first.
- Jobs submitted to `kingspeak` may require `sacct -M kingspeak ...` when queried from another login environment such as `granite`.
- When in doubt, check the job's cluster or partition first and retry with explicit cluster selection, for example `sacct -M CLUSTER ...`, `squeue -M CLUSTER -j JOBID`, or `scontrol -M CLUSTER show job JOBID`.

Also inspect:
- the submitted batch script
- stdout and stderr
- launcher details such as `srun`, `mpirun`, `torchrun`, `python`, or workflow-engine wrappers
- thread or worker controls such as `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `NUMEXPR_NUM_THREADS`, `--threads`, `--cpus`, `-t`, `num_workers`, and dataloader settings

If the user is changing or submitting a job script, also use `partition-selection`.

## Run The Parser

Prefer the bundled parser for repeated audits:

```bash
python3 scripts/slurm_efficiency_report.py JOBID
```

Use saved command output when direct scheduler queries are unavailable:

```bash
python3 scripts/slurm_efficiency_report.py JOBID \
  --sacct-path /path/to/sacct.tsv \
  --sstat-path /path/to/sstat.tsv
```

Read [references/metrics-and-tuning.md](references/metrics-and-tuning.md) if you need the detailed heuristics or field meanings.

## Interpret CPU Efficiency

Use `CPUTimeRAW / (AllocCPUS * ElapsedRaw)` as the primary CPU efficiency estimate.

Interpret it conservatively:
- `>= 0.8`: CPU allocation is probably well matched.
- `0.4 - 0.79`: Mixed; inspect whether the workload has serial phases, I/O waits, or over-allocation.
- `< 0.4`: Strong signal that the job requested more CPU than it used, or that the code was blocked on I/O, synchronization, or GPUs.

Translate findings into settings:
- Single-process threaded code: tune `--cpus-per-task` to the real thread count and set `OMP_NUM_THREADS` or the tool-specific `--threads`.
- MPI code: tune `--ntasks` first, then `--cpus-per-task` for hybrid MPI/OpenMP cases.
- Python data pipelines: if GPUs are idle and CPU efficiency is also low, inspect dataloader workers and preprocessing concurrency.
- Workflow wrappers: verify the wrapper's internal `--threads` or task-level parallelism matches SLURM allocation.

## Interpret GPU Efficiency

CHPC records `gres/gpu`, `gres/gpumem`, and `gres/gpuutil` in Slurm accounting. These values are sampled, not continuous profiling.

Use `TRESUsageInAve` or `TRESUsageInMax` from `sstat` first. Fall back to `sacct` if step data is missing.

Interpret GPU signals:
- High `gpuutil` and low CPU efficiency: the job may be GPU-bound; avoid adding more CPUs unless they relieve input bottlenecks.
- Low `gpuutil` and low CPU efficiency: likely a CPU, I/O, or launch bottleneck; inspect threads, workers, preprocessing, and storage placement.
- Low `gpuutil` with many allocated GPUs: likely too many GPUs, too small a batch size, or poor rank-to-GPU mapping.
- High `gpumem` and low `gpuutil`: the model fits but the GPUs are waiting; look at input throughput and synchronization.

Do not treat one low sample as proof. Prefer consistent patterns across the batch step and logs.

## Recommend Concrete Changes

Always make recommendations in two layers:

1. Batch-script changes
- adjust `--ntasks`
- adjust `--cpus-per-task`
- reduce or increase `--gres=gpu:N`
- right-size `--mem`
- keep `--nodes`, `--ntasks`, `--account`, and `--time` explicit

2. Runtime changes
- set thread environment variables explicitly
- change tool-specific `--threads` or worker counts
- change MPI rank count, GPU rank mapping, or per-rank CPU binding
- change dataloader worker count, batch size, gradient accumulation, or preprocessing strategy

When possible, tie every recommendation to one observed metric. Avoid generic advice that is not supported by the accounting data or logs.

## Escalate Or Redirect

Use `job-triage` if the job also failed, timed out, or never used the requested GPUs at all.

Use `storage-placement` when low utilization appears to be caused by heavy I/O from home or other durable storage instead of scratch.

Use `software-environments` when module or environment issues explain the poor resource use.
