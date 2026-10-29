# Apptainer / Singularity Containers on CHPC

## Load the Module

```bash
module spider apptainer    # check available versions
module load apptainer
```

`singularity` commands still work — Apptainer maintains backwards compatibility.

---

## Pulling and Building Images

**Pull directly (re-pulled each run, slower for large images):**
```bash
singularity shell docker://ubuntu:latest
singularity exec docker://biocontainers/blast:2.2.31 blastp -help
```

**Build to a local `.sif` file (recommended — faster startup, cached locally):**
```bash
singularity build myimage.sif docker://org/image:tag
singularity build blast.sif docker://biocontainers/blast:2.2.31
```

Store `.sif` files in scratch (`/scratch/general/vast/$USER/`) — they can be large.

**BioContainers** require explicit version tags:
```bash
singularity build blast.sif docker://biocontainers/blast:2.2.31   # correct
singularity build blast.sif docker://biocontainers/blast:latest   # may fail
```

---

## Running Containers

```bash
# Execute a single command
singularity exec myimage.sif mycommand --args

# Interactive shell
singularity shell myimage.sif

# GPU access (exposes host CUDA stack)
singularity exec --nv myimage.sif mycommand

# Suppress automatic CHPC bind mounts (needed when building)
unset APPTAINER_BINDPATH
```

**CHPC auto-mounts** `/uufs` and `/scratch` into every container — no `--bind` needed for home directory or scratch access.

---

## Using Containers in SLURM Job Scripts

```bash
#!/bin/bash
#SBATCH --ntasks=4
#SBATCH --mem=16G
#SBATCH --time=2:00:00

module load apptainer

CONTAINER=/scratch/general/vast/$USER/myimage.sif
singularity exec $CONTAINER mycommand --input $SLURM_SUBMIT_DIR/input.txt \
    --output $SLURM_SUBMIT_DIR/output.txt
```

For GPU jobs, add `--gres=gpu:1` to SBATCH directives and `--nv` to the singularity exec line.

---

## Building Custom Containers

Requires an interactive job (cannot build on login nodes):

```bash
salloc -N 1 -n 16 -A notchpeak-shared-short -p notchpeak-shared-short -t 2:00:00
module load apptainer
unset APPTAINER_BINDPATH    # required — prevents build errors from CHPC bind paths

apptainer build mycontainer.sif MyDefinitionFile.def
```

**Definition file example:**
```
Bootstrap: docker
From: ubuntu:22.04

%post
    apt-get update && apt-get install -y python3 python3-pip
    pip3 install numpy scipy

%environment
    export PATH=/usr/local/bin:$PATH
```

---

## Modifying an Existing Container

Build a writable sandbox, modify it, then convert back to `.sif`:

```bash
apptainer build --sandbox mycontainer/ docker://ubuntu:latest
apptainer shell -w mycontainer/    # enter writable shell, make changes
apptainer build my-modified.sif mycontainer/
```

---

## Creating a Module for a Container

To load a container via the module system (useful for OOD or shared team use):

1. Copy the template: `cp /uufs/chpc.utah.edu/sys/modulefiles/templates/container-template.lua ~/MyModules/mytool/1.0.lua`
2. Edit the `.lua` file to set the container path and define command aliases
3. Enable your module directory: `module use ~/MyModules`
4. Load it: `module load mytool/1.0`

If scripts inside the container call the same binary recursively, use the `-e` flag in the module's exec line to prevent "singularity: command not found" errors.

---

## When to Use Containers

- Tool has a published Docker or BioContainers image
- Software has GLIBC/OS-level conflicts with CHPC's Rocky Linux 8 environment
- Environment must be exactly reproducible or shared with collaborators off-cluster
- Complex multi-tool bioinformatics pipelines (e.g., Nextflow/Snakemake workflows with per-tool containers)

---

## Reference

CHPC Singularity/Apptainer documentation: https://www.chpc.utah.edu/documentation/software/singularity.php
