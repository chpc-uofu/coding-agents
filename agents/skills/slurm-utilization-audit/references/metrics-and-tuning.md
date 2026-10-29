# Metrics And Tuning

## Collection Commands

Primary collection:

```bash
sacct -j JOBID --parsable2 --units=M \
  --format=JobIDRaw,JobName,State,ElapsedRaw,AllocCPUS,AllocTRES,ReqMem,MaxRSS,TotalCPU,CPUTimeRAW,TRESUsageInAve,TRESUsageInTot
```

```bash
sstat -j JOBID.batch --parsable2 --units=M \
  --format=JobID,AveCPU,AveRSS,MaxRSS,TRESUsageInAve,TRESUsageInMax
```

Useful follow-up:

```bash
scontrol show job JOBID
```

## Field Notes

- `ElapsedRaw`: wallclock seconds
- `AllocCPUS`: CPUs reserved for the step or job
- `CPUTimeRAW`: total CPU seconds consumed
- `ReqMem`: requested memory
- `MaxRSS`: high-water memory use
- `AllocTRES`: reserved resources including GPUs
- `TRESUsageInAve`: average sampled TRES usage
- `TRESUsageInTot`: cumulative or total TRES usage when available
- `TRESUsageInMax`: peak sampled TRES usage for the step

CHPC Slurm accounting includes:
- `gres/gpu`
- `gres/gpumem`
- `gres/gpuutil`

Accounting samples are not a replacement for live profiling. Treat them as job-summary evidence.

## CPU Heuristics

CPU efficiency formula:

```text
cpu_efficiency = CPUTimeRAW / (AllocCPUS * ElapsedRaw)
```

Interpretation:
- `>= 0.8`: good match between allocation and use
- `0.4 - 0.79`: investigate partial underuse, serial phases, or blocking
- `< 0.4`: likely over-allocation or bottleneck outside CPU compute

Common diagnoses:
- Low CPU efficiency, no GPUs, low memory use: too many CPUs or threads requested
- Low CPU efficiency, GPUs allocated, low GPU utilization: input pipeline or launch bottleneck
- Low CPU efficiency, high GPU utilization: CPU request may still be too high for a GPU-bound job
- Low CPU efficiency, high MaxRSS near ReqMem: memory pressure or paging may have stalled the job

## GPU Heuristics

Use the batch step if possible. Parent job rows are less reliable for GPU interpretation.

Interpretation:
- `gpuutil >= 70`: GPUs are likely meaningfully busy
- `gpuutil 25 - 69`: mixed; inspect scaling and stalls
- `gpuutil < 25`: strong sign of idle or underfed GPUs

Common diagnoses:
- Low `gpuutil`, low `gpumem`: too many GPUs, CPU bottleneck, or application never saturated the devices
- Low `gpuutil`, high `gpumem`: synchronization, batch-size, or dataloader problem
- High `gpuutil`, high `gpumem`: workload is likely GPU-bound; reduce CPU over-allocation before changing GPU count

## Recommendation Patterns

Translate evidence into direct edits.

### Over-allocated CPUs

Signals:
- low CPU efficiency
- few active processes in logs
- serial or lightly threaded application

Recommend:
- reduce `--cpus-per-task`
- reduce `--ntasks`
- set explicit thread controls to the intended value
- match tool-specific `--threads` to the reserved CPUs

### Underfed GPUs

Signals:
- low `gpuutil`
- low or moderate CPU efficiency
- logs show data preparation, downloads, decompression, or per-batch Python overhead

Recommend:
- increase dataloader or preprocessing workers only up to the allocated CPUs
- move I/O-heavy inputs to scratch when appropriate
- increase per-GPU batch size if memory allows
- reduce GPU count if scaling is poor

### MPI Or Multi-GPU Mismatch

Signals:
- many tasks or GPUs reserved
- low aggregate utilization
- logs suggest incorrect rank count or device mapping

Recommend:
- align MPI ranks with GPUs when using one rank per GPU
- verify `srun` or launcher options for rank placement and CPU binding
- avoid requesting more GPUs than the code can map or keep busy

### Memory Over-allocation

Signals:
- `MaxRSS` far below `ReqMem`

Recommend:
- reduce `--mem` while leaving a safety margin
- note that reserved memory still affects queueing and allocation efficiency
