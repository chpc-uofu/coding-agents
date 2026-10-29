---
name: gpu-use
description: Guide GPU job submission at CHPC. Use when writing GPU job scripts, choosing a GPU type or partition, adding --gres directives, checking GPU availability, loading CUDA or nvhpc modules, running GPU workloads inside Singularity containers, or monitoring and profiling GPU jobs.
---

## Find Available GPUs

Run the GPU recommender first. It combines live `mychpc`, `freegpus`, and queue-depth signals with owner-usage data to rank candidates and emit a ready-to-paste SLURM snippet:

```bash
~/GPU_recommender/chpc-guest-gpu-recommender
```

Key flags:

| Flag | Default | Purpose |
|---|---|---|
| `--gpus N` | 1 | Number of GPUs needed |
| `--mode sbatch\|salloc` | salloc | Output format |
| `--time HH:MM:SS` | 01:00:00 | Wall time |
| `--nodes N` | 1 | Node count |
| `--ntasks N` | 1 | Task count |
| `--json` | off | Machine-readable output |

The recommender skips GH200 by default — it pairs the GPU with an Arm CPU and requires Arm-compatible software.

**Fallback** (no recommender or raw counts needed):

```bash
freegpus                # idle GPU counts per partition
si2 -M all -a          # all partitions with gres and feature flags
```

## Request GPUs in SLURM

```
--gres=gpu[:<gres_type>]:<count>
```

- Omit `<gres_type>` to get any available GPU.
- Always pair with `--partition`, `--account`, `--time`, `--nodes`, `--ntasks`.
- **Granite cluster** also requires `--qos` (the recommender fills this in automatically).

**MIG slices** (H200 only — fractional GPU partitions):

```bash
--gres=gpu:h200_1g.18gb:1   # 1/7 slice, 18 GB
--gres=gpu:h200_2g.35gb:1   # 2/7 slice, 35 GB
--gres=gpu:h200_3g.71gb:1   # 3/7 slice, 71 GB
```

**Interactive example:**

```bash
salloc -N 1 -n 2 -t 01:00:00 \
  -p notchpeak-gpu -A notchpeak-gpu \
  --gres=gpu:3090:1
```

**Memory note:** Default SLURM allocation is 2 GB RAM per core. Add `--mem=Xg` if your workload needs more. Use `--mem=0` only if you need exclusive node use.

A GPU may show idle but still be unavailable if the node's host RAM is fully consumed by other jobs.

## Load GPU Software

**CUDA Toolkit** (most common):

```bash
module spider cuda          # list available versions
module load cuda/<version>  # load chosen version
```

**NVIDIA HPC SDK** (Fortran, OpenACC, OpenMP):

```bash
module load nvhpc
```

## Verify GPU Allocation

After getting an allocation, confirm GPUs are visible:

```bash
```

## Monitor GPU During a Job

Add this line **before** your program launch in the batch script:

```bash
/uufs/chpc.utah.edu/sys/installdir/chpcscripts/gpu/gpu-monitor.sh &
```

Writes `$SLURM_JOBID.gpulog` with GPU utilization sampled every 5 minutes.

Monitor a running job from a second terminal:

```bash
srun --pty --overlap --jobid $JOBID /usr/bin/nvidia-smi
```

## Profile a GPU Job

GPU hardware performance counters are disabled by default. Enable profiling by adding `nsight=1` to the gres request:

```bash
# batch script
#SBATCH --gres=gpu:a40:1,nsight:1

# interactive
salloc -N 1 -n 4 -A owner-gpu-guest -p notchpeak-gpu-guest \
  -t 1:00:00 --gres=gpu:a40:1,nsight:1
```

Profiling tools available after loading cuda:

- `nsight-sys` — Nsight Systems (timeline/visual)
- `ncu` — Nsight Compute (kernel-level counters)
- `cuda-gdb` — GPU debugger
- DDT — GUI debugger with CUDA and OpenACC support

## GPU in Singularity/Apptainer Containers

Pass NVIDIA GPU support through to a container with the `--nv` flag:

```bash
# batch / non-interactive
singularity exec --nv myimage.sif python train.py

# interactive shell inside container
singularity shell --nv myimage.sif

# run a specific command
singularity run --nv myimage.sif
```

`--nv` binds the host NVIDIA driver and CUDA libraries into the container. The container's own CUDA toolkit version must be **compatible** with the host driver (`nvidia-smi` shows the driver version and the maximum CUDA version it supports).

`CUDA_VISIBLE_DEVICES` is set by SLURM and honored inside the container — no extra configuration needed.

## GPU Selection Guidance

See `references/gpu-hardware.md` for the full table of gres types, VRAM, clusters, and compute capabilities.

Quick rules:
- **FP64 / double-precision science**: A100, H100, H200, GH200 (avoid consumer RTX cards)
- **Deep learning (FP32/FP16/BF16)**: any Tensor Core GPU (Volta and later)
- **Large models / big VRAM**: H200 (141 GB), H100 NVL / GH200 / RTX PRO 6000 (96 GB), A100-80GB (80 GB)
- **Quick interactive / small workload**: MIG slice (`h200_1g.18gb`), T4, RTX 2000 Ada
- **Arm caveat**: GH200 is on an Arm (AArch64) node — only use if your software stack is Arm-compatible

## Escalate / Redirect

- **Job ran but GPU utilization was low** → use `slurm-utilization-audit`
- **Job failed, OOM, timed out, or never received GPUs** → use `job-triage`
- **Partition selection or general job script writing** → use `partition-selection`
- **Module or environment setup issues** → use `software-environments`
- **Container creation or Singularity image building** → use `software-environments`

## Coding Agents running in GPU interactive slurm session
- **Sandbox blocking GPU access?** If `nvidia-smi` or CUDA can't see the GPU from your sandboxed shell inside a GPU job, run the command through Slurm instead:
  `srun --overlap --jobid $SLURM_JOB_ID <command>`.
