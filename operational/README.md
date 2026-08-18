# Operational MPAS-JEDI Driver

## Overview

`jedi.oper.sh` is the operational driver used to prepare and execute MPAS-JEDI
variational data assimilation.

The script coordinates the complete assimilation workflow, including:

- selection of the assimilation method;
- selection of the MPAS/JEDI analysis resolution;
- preparation of background and trajectory states;
- direct MPAS-to-MPAS resolution remapping;
- preparation of runtime namelists and streams;
- generation of the operational `jedi.yaml`;
- selection of B-matrix/SABER resources;
- observation configuration;
- execution of MPAS-JEDI;
- construction of the final native-resolution analyzed restart.

The operational template used to generate the runtime YAML is:

    operational/jedi.303.yaml

The production versions are normally installed under:

    $MODEL_ROOT/slurm/jedi.oper.sh
    $MODEL_ROOT/name/jedi/jedi.303.yaml

---

## Main design

The native MPAS forecast is maintained on the approximately 12-km global mesh:

    x1.4096002
    nCells = 4096002

The variational analysis may be performed on:

    12 km  - native x1.4096002
    24 km  - x1.1024002
    30 km  - x1.655362

Using a coarser variational geometry substantially reduces the computational
cost of MPAS-JEDI while allowing the operational forecast to remain at native
12-km resolution.

Conceptually:

    Native 12-km MPAS forecast
                |
                |
                +-----------------------------+
                |                             |
                | if JEDI resolution = 12 km |
                |                             |
                v                             |
            MPAS-JEDI                         |
                                              |
                +-----------------------------+
                |
                | if JEDI resolution = 24/30 km
                v
       Direct MPAS-to-MPAS remapping
                |
                v
         24-km or 30-km state
                |
                v
             MPAS-JEDI
                |
                v
       analyzed low-resolution state
                |
                v
       direct remap back to 12 km
                |
                v
       native operational analysis

---

## Configuration

The operational script is intentionally parameter driven.

Important configuration controls include the analysis method, variational
resolution, ensemble usage, trajectory handling, observation configuration,
B-matrix selection, and MPI decomposition.

The script derives the corresponding MPAS geometry from the requested
variational resolution.

For example:

    JEDI_VAR_RESOLUTION=12

uses the native MPAS geometry.

    JEDI_VAR_RESOLUTION=24

uses:

    x1.1024002
    nCells = 1024002

and:

    JEDI_VAR_RESOLUTION=30

uses:

    x1.655362
    nCells = 655362

---

## Runtime YAML

`jedi.oper.sh` does not normally use a hand-written final `jedi.yaml`.

Instead, it starts from:

    jedi.303.yaml

and constructs the operational runtime YAML according to the selected
assimilation configuration.

This permits one common template to support different operational modes
without maintaining several independent YAML files.

The generated YAML contains the model geometry, background state,
observations, variational configuration, SABER/BUMP resources, trajectory
information, and output configuration required by MPAS-JEDI.

---

## Atmospheric variables

The operational workflow includes the principal MPAS atmospheric analysis
variables, including dynamical, thermodynamic, moisture, and hydrometeor
fields.

Typical analyzed fields include:

    pressure_p
    rho
    qv
    qc
    qr
    qi
    qs
    qg
    surface_pressure
    theta
    u
    uReconstructZonal
    uReconstructMeridional

The exact runtime variable lists are generated from the operational
configuration and the JEDI YAML template.

---

## Direct MPAS remapping

When the JEDI analysis resolution differs from the native forecast resolution,
the script uses the direct MPAS-to-MPAS remapper.

The remapping implementation is documented in:

    ../remap/README.md

The main operational resources are configured through:

    MPAS_REMAP_DATA_ROOT
    MPAS_REMAP_WEIGHT_ROOT
    MPAS_REMAP_TEMPLATE_ROOT
    MPAS_REMAP_GRID_ROOT
    MPAS_REMAP_EXE

The external installation has the general structure:

    $MODEL_ROOT/src/mpas/remap/
        grids/
        weights/
        templates/

and:

    $MODEL_ROOT/src/util/mpas_remap_state/
        mpas_remap_state

The actual NetCDF weights and restart templates are intentionally not stored
in Git because of their size.

---

## Forward remapping

For a 24-km or 30-km analysis, native 12-km MPAS states are converted directly
to the target MPAS mesh.

For a time-dependent variational configuration, the required trajectory
states can include:

    T-3h
    T
    T+3h

The individual direct-remapping operations can be launched concurrently.

Each remapping operation uses one process with OpenMP threads rather than a
large MPI job.

---

## OpenMP isolation

The direct remapper uses OpenMP, while MPAS-JEDI is primarily executed with
MPI.

The remapper OpenMP environment is isolated inside its execution context.

For example:

    OMP_NUM_THREADS=64

may be used by the remapper, while the surrounding MPAS-JEDI environment
remains:

    OMP_NUM_THREADS=1

This isolation is important.

Allowing the remapper's OpenMP setting to leak into a subsequent pure-MPI MPAS
run can cause extreme CPU oversubscription.

---

## Analysis return to native resolution

For analyses performed on 24-km or 30-km geometry, the complete analyzed
low-resolution state is remapped back to the native 12-km mesh.

The native 12-km analysis-time restart is used as the target structural
reference.

Only the required analyzed variables are then overlaid on the original native
restart.

This design preserves the native MPAS fields that are not part of the JEDI
control/analysis state.

Conceptually:

    low-resolution analyzed state
                |
                v
       direct remap to 12 km
                |
                v
       12-km analysis carrier
                |
                | analyzed fields only
                v
       original native restart
                |
                v
       final operational analysis

---

## B-matrix and SABER resources

The workflow supports native and lower-resolution B-matrix resources.

The selected B-matrix location follows the JEDI analysis resolution rather
than assuming that the forecast and analysis grids are identical.

The repository also contains the associated B-matrix workflows under:

    ../bmatrix/

These include MPAS-JEDI/SABER/BUMP preparation and training workflows used to
construct the covariance resources consumed operationally by `jedi.oper.sh`.

---

## MPAS runtime resources

The script prepares the MPAS runtime configuration required by MPAS-JEDI,
including:

    namelist.atmosphere
    streams.atmosphere
    stream_list.atmosphere.*
    geovars.yaml
    keptvars.yaml
    obsop_name_map.yaml

The operational MPAS/JEDI resource files should remain consistent with the
MPAS-JEDI version used by the production installation.

---

## Execution

The script is designed for execution through Slurm.

A typical invocation is performed from the operational workflow rather than
running individual JEDI executables manually.

The script prepares the required files and then executes the appropriate
MPAS-JEDI variational application with `srun`.

Exact node and task counts depend on the selected analysis configuration and
resolution.

---

## Logging and validation

The workflow performs validation before major processing stages.

Typical checks include:

- existence of native background states;
- consistency of target mesh dimensions;
- availability of target invariant files;
- availability of remapping weights and templates;
- availability of B-matrix resources;
- existence and usability of trajectory states;
- successful generation of the runtime YAML;
- successful creation of the final analyzed state.

Failures are reported with explicit diagnostic messages rather than silently
continuing with incomplete input.

---

## Operational file philosophy

The workflow distinguishes between:

1. native forecast state;
2. variational-resolution working state;
3. JEDI analysis output;
4. remapped analysis carrier;
5. final native operational analysis.

This distinction is deliberate.

Large native MPAS files are normally linked rather than unnecessarily copied
where possible.

Temporary low-resolution states are kept under the assimilation working tree,
while permanent meshes, weights, templates, and B-matrix resources reside
under their model installation directories.

---

## Related files

Main operational driver:

    operational/jedi.oper.sh

JEDI YAML template:

    operational/jedi.303.yaml

Direct MPAS remapper:

    remap/src/mpas_remap_state_v3_restart_fastio.F90

Weight generation:

    remap/generate_mpas_weights_robust.slurm

Direct-remapping documentation:

    remap/README.md

B-matrix workflows:

    bmatrix/

Operational Spack environment:

    spack/

---

## Repository scope

This repository stores source code, scripts, configuration templates, and
documentation.

Large operational data are intentionally excluded, including:

- MPAS restart files;
- remapping NetCDF weight files;
- target restart templates;
- observation datasets;
- generated runtime products;
- operational logs.

The repository is intended to document and reproduce the workflow while
keeping machine-generated and very large datasets outside Git.
