---
name: software-environments
description: Use when a user needs to install software, load packages, set up a Python environment, create a conda environment, or run a container on CHPC. Covers LMOD modules, conda/mamba with Miniforge, Python venv and uv, and Singularity/Apptainer containers. Always check for an existing module before installing to user space.
---

# CHPC Software Environments

Use this skill whenever a user needs to install or set up software on CHPC. Follow the decision tree below — always check for an existing module first before directing users to install anything themselves.

---

## Step 1: Check for an Existing Module

Before installing anything, search CHPC's 1,000+ installed packages:

```bash
module spider <name>          # finds all versions, including hidden ones
module spider <name>/<version> # shows prerequisite modules required to load it
module keyword <term>         # search by keyword if you're not sure of the name
```

Use `module spider`, not `module avail` — avail only shows what's accessible given currently loaded modules and will miss things behind a hierarchy.

If the module exists: load it and stop here. For job scripts, add the `module load` line before any application commands.

**Never unload `chpc/1.0`** — it is sticky and required for the CHPC environment.

---

## Step 2: Decision Tree (if no module exists)

### Any package requires conda or has complex cross-language dependencies?
→ **Conda/mamba** (see below)
→ Rule: if *any* package in the environment needs conda, use conda for *all* packages in that environment — do not mix with pip

### Pure Python packages, simple pip-installable deps, no conda needed?
→ **Python venv or uv** (see below)

### Need a fixed, shareable, or immutable environment? Bioinformatics tool with a Docker image?
→ **Apptainer/Singularity container** (see `references/containers.md`)

---

## Conda / Mamba (Miniforge)

Use CHPC's centrally-maintained Miniforge — do not install your own unless you need full control.

```bash
module spider miniforge3          # check available versions
module load miniforge3/24.9.0     # load it (confirm current version with spider)
```

**Do not add `module load miniforge3` to `~/.custom.sh` or `~/.custom.csh`** — auto-loading custom Python installations breaks FastX and OnDemand remote connections.

### Create and use an environment

```bash
mamba create -n myenv python=3.11   # create environment
conda activate myenv                 # activate (use conda, not mamba, to activate)
mamba install scipy numpy            # install packages
mamba install -c conda-forge PACKAGE # use conda-forge for broader package availability
pip install PACKAGE                  # pip only as a last resort — loses conda conflict resolution
conda deactivate
```

### Key rules
- Use **mamba** to install and create, **conda** to activate/deactivate
- Use **conda-forge** channel; consider removing the commercial `defaults` channel to avoid licensing issues
- Create **separate environments** for projects with conflicting dependencies
- Environments default to `$HOME/.conda/envs` — this can fill your 50 GB home quota fast. Redirect large envs:
  ```bash
  conda config --add envs_dirs /scratch/general/vast/$USER/conda-envs
  ```
- For parallel jobs using MKL libraries, set `OMP_NUM_THREADS=1` to prevent a single job step from consuming all cores. For OpenBLAS, use `export OMP_NUM_THREADS=$SLURM_NTASKS`.

### In job scripts
```bash
module load miniforge3/24.9.0
conda activate myenv
# ... job commands ...
conda deactivate
```

### In OOD Jupyter
In the Jupyter app form, select **"Custom (Environment setup below)"** for Python version and enter:
```
module load miniforge3/24.9.0
conda activate myenv
```

---

## Python venv / uv

Lighter weight than conda — good for pure pip-installable packages.

### Option A: CHPC setup script (recommended for new users)
```bash
module load python
/uufs/chpc.utah.edu/sys/installdir/python/modules/venv_setup
```
The script guides through creation and optionally sets up a module file so the environment can be loaded with `module load`.

### Option B: Manual venv
```bash
module load python/3.13.5           # or whichever version you need
python -m venv ~/my-python-venvs/myenv
source ~/my-python-venvs/myenv/bin/activate
pip install --upgrade pip
pip install PACKAGE
deactivate
```

### Option C: uv (fastest, drop-in for venv + pip)
```bash
module load uv/0.10.9               # check current version: module spider uv
uv venv ~/my-python-venvs/myenv
source ~/my-python-venvs/myenv/bin/activate
uv pip install PACKAGE
```

### Key rules
- Venvs are **not portable** — document how you built it; don't copy between systems
- For OOD Jupyter, install `jupyter` inside the venv and load the env via the "Environment Setup" field
- To use via the module system, create a module file at `~/my-python-modules/myenv/latest.lua`
  (use `/uufs/chpc.utah.edu/sys/modulefiles/templates/` as a starting template)

### In job scripts
```bash
module load python/3.13.5
source ~/my-python-venvs/myenv/bin/activate
# ... job commands ...
```

---

## Containers (Apptainer / Singularity)

For detailed usage see `references/containers.md`. Quick reference:

```bash
module load apptainer

# Pull and cache as a .sif file (faster startup than pulling each run)
singularity build myimage.sif docker://org/image:tag

# Run a command
singularity exec myimage.sif mycommand --args

# GPU jobs
singularity exec --nv myimage.sif mycommand

# Interactive shell inside container
singularity shell myimage.sif
```

CHPC auto-mounts `/uufs` and `/scratch` — no manual `--bind` needed for home or scratch access.

Use containers when:
- A tool publishes a Docker/BioContainers image
- The environment needs to be exactly reproducible or shared with collaborators
- The software has GLIBC or OS-level dependency conflicts with CHPC's Rocky Linux 8 environment
