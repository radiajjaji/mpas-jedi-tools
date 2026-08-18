# Direct MPAS-to-MPAS State Remapper

## Overview

This directory contains the direct MPAS-to-MPAS state remapping tools used by
the operational MPAS-JEDI workflow.

The purpose of the remapper is to convert a native MPAS atmospheric restart
from one MPAS mesh directly to another MPAS mesh without passing through WPS,
GRIB, or an intermediate regular latitude/longitude grid.

The current operational application is:

    Native 12-km MPAS
           |
           | direct MPAS-to-MPAS remapping
           |
           +--------------------+
           |                    |
           v                    v
      24-km MPAS          30-km MPAS
      x1.1024002          x1.655362
           |                    |
           +---------+----------+
                     |
                     v
                  MPAS-JEDI

This direct remapping replaces the previous `wps_init_atmosphere`-based
conversion used to prepare lower-resolution states for MPAS-JEDI.

---

## Directory contents

    remap/
    |-- README.md
    |-- Makefile
    |-- generate_mpas_weights_robust.slurm
    `-- src/
        `-- mpas_remap_state_v3_restart_fastio.F90

The large NetCDF weight and restart-template files are not stored in Git.

---

## Source and target meshes

The current operational source mesh is the native approximately 12-km global
MPAS mesh:

    x1.4096002
    nCells = 4096002

Two lower-resolution target meshes are currently supported.

### 24-km target

    x1.1024002
    nCells = 1024002
    nEdges = 3072000
    nVertLevels = 56

### 30-km target

    x1.655362
    nCells = 655362
    nEdges = 1966080
    nVertLevels = 56

---

## Basic principle

The remapper operates directly between two MPAS unstructured meshes.

For each fixed source/target mesh pair, sparse remapping weights are generated
once and reused for every forecast/assimilation cycle.

Two weight sets are used:

    smooth weights
    conservative weights

The weight files contain only the required source-to-target connections rather
than a dense source-by-target matrix.

Conceptually, a remapped field is obtained from

                 N
    X_target =  SUM  w_i X_source(i)
                i=1

where only source cells contributing to a particular target cell are stored.

---

## Restart template

The program does not construct a complete MPAS restart file from scratch.

Instead, it starts from a valid MPAS restart produced on the target mesh. This
file is used as a structural template.

Current operational templates are named:

    restart.24km.x1.1024002.template.nc
    restart.30km.x1.655362.template.nc

The template provides the correct target:

* MPAS dimensions
* mesh dimensions
* vertical dimensions
* static fields
* physics fields
* NetCDF structure
* attributes and metadata

The template is copied to the requested output restart and the atmospheric
state is replaced by the remapped source state.

The original date contained in the template is therefore not important. The
generated restart receives the valid time of the source state.

For example:

    source:
        2026-08-17_21:00:00

    template:
        2026-08-17_15:00:00

    generated restart:
        2026-08-17_21:00:00

---

## Atmospheric state remapping

Different atmospheric quantities require different remapping treatments.

### Density

Density (`rho`) is conservatively remapped.

Conceptually:

    rho_target = C(rho_source)

where `C` represents the conservative remapping operator.

### Potential temperature

Potential temperature (`theta`) is treated using a density-weighted
conservative remapping.

Conceptually:

                        C(rho * theta)
    theta_target = --------------------------
                           C(rho)

This avoids independently averaging potential temperature without accounting
for atmospheric mass.

### Moisture and hydrometeors

The remapper directly processes the MPAS moisture and hydrometeor state,
including:

    qv
    qc
    qr
    qi
    qs
    qg

This preserves the native MPAS representation and avoids conversion through
external meteorological formats.

### Dynamical fields

The required MPAS dynamical fields are also transferred to the target mesh.

The program additionally creates the reconstructed wind variables in the
target restart when required and when they are not already present in the
template.

---

## Weight generation

Weights are generated with:

    generate_mpas_weights_robust.slurm

They only need to be generated once for each source/target mesh combination.

Examples:

    x1.4096002 -> x1.1024002
    x1.4096002 -> x1.655362

The operational installation keeps these under a structure such as:

    $MODEL_ROOT/src/mpas/remap/weights/

Large generated NetCDF weight files are intentionally excluded from Git.

---

## Template generation

A target template must be generated from a valid MPAS restart on the desired
target mesh.

The template must have the same mesh and vertical configuration expected by
the remapper and MPAS-JEDI.

The operational templates are stored under:

    $MODEL_ROOT/src/mpas/remap/templates/

For example:

    restart.24km.x1.1024002.template.nc
    restart.30km.x1.655362.template.nc

These files are large and are intentionally excluded from Git.

---

## Building

The supplied `Makefile` builds the Fortran remapper.

After loading the appropriate compiler and NetCDF environment:

    cd remap
    make clean
    make

The resulting executable is installed operationally as:

    $MODEL_ROOT/src/util/mpas_remap_state/mpas_remap_state

---

## Running

The remapper takes five principal inputs:

    mpas_remap_state \
        SOURCE_RESTART \
        TARGET_TEMPLATE \
        SMOOTH_WEIGHTS \
        CONSERVATIVE_WEIGHTS \
        OUTPUT_RESTART

For example:

    mpas_remap_state \
        restart.12km.nc \
        restart.30km.x1.655362.template.nc \
        x1.4096002_to_x1.655362.smooth.nc \
        x1.4096002_to_x1.655362.conserve.nc \
        restart.30km.nc

---

## OpenMP parallelism

The current implementation uses OpenMP to accelerate the remapping.

For example, using eight CPU threads:

    export OMP_NUM_THREADS=8
    export OMP_DYNAMIC=FALSE

    srun -p dev \
        -N 1 \
        -n 1 \
        --cpus-per-task=8 \
        --cpu-bind=cores \
        mpas_remap_state \
        SOURCE \
        TEMPLATE \
        SMOOTH_WEIGHTS \
        CONSERVATIVE_WEIGHTS \
        OUTPUT

The remapper is therefore normally executed as one process with multiple
OpenMP threads.

---

## Integration with MPAS-JEDI

The operational driver is:

    operational/jedi.oper.sh

When a lower-resolution JEDI geometry is requested, the script selects the
appropriate:

* target MPAS mesh
* target invariant file
* remapping weights
* target restart template
* target B-matrix
* remapping executable

The relevant operational resource tree is:

    $MODEL_ROOT/src/mpas/remap/
        weights/
        templates/
        grids/

and the executable is configured through:

    MPAS_REMAP_EXE

The target resolution is selected from the JEDI variational resolution.

For example:

    JEDI_VAR_RESOLUTION=24

selects the `x1.1024002` target, while

    JEDI_VAR_RESOLUTION=30

selects the `x1.655362` target.

This permits the native high-resolution MPAS forecast to remain at 12 km while
the variational analysis can operate on a less expensive 24-km or 30-km
geometry.

---

## Validation

The optimized remapper was compared against the reference implementation for
the principal three-dimensional atmospheric variables.

The tested fields included:

    rho
    theta
    qv
    qc
    qr
    qi
    qs
    qg
    w

The comparison produced:

    correlation = 1.0
    RMSE        = 0.0
    max diff    = 0.0

for the tested outputs.

The optimized implementation therefore reproduced the reference remapped
state while providing substantially improved execution performance.

---

## Why this approach?

The direct MPAS-to-MPAS approach has several practical advantages for an
operational MPAS-JEDI system:

* avoids GRIB intermediate files;
* avoids interpolation through a regular grid;
* removes the WPS/init_atmosphere conversion from the cycling path;
* operates directly on native MPAS restart states;
* reuses precomputed sparse weights;
* preserves the target MPAS restart structure through a validated template;
* supports different JEDI analysis resolutions from the forecast resolution;
* reduces the cost of preparing lower-resolution JEDI trajectories.

The result is a direct path:

    MPAS forecast restart
             |
             v
    sparse MPAS-to-MPAS remapping
             |
             v
    target MPAS restart
             |
             v
          MPAS-JEDI
