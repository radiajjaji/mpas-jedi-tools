# MPAS-JEDI 4D-FGAT Operational Example

## Overview

This directory contains the complete operational log from a successful
native-resolution MPAS-JEDI 4D-FGAT assimilation cycle.

The example is retained as a reference for:

- operational MPAS-JEDI execution;
- 4D-FGAT trajectory preparation;
- observation ingestion and QC;
- radiance variational bias correction;
- SABER/BUMP background-error covariance;
- outer- and inner-loop minimization;
- analysis increments;
- observation-space diagnostics;
- construction of the final native MPAS restart-compatible analysis.

The original unmodified operational log is:

    jedi.oper303.out

---

## Run summary

| Property | Value |
|---|---|
| Assimilation method | 4D-FGAT |
| Cost function | 4D-Var |
| Analysis time | 2026-08-16 00:00:00 UTC |
| Window start | 2026-08-15 21:00:00 UTC |
| Window end | 2026-08-16 03:00:00 UTC |
| Window length | 6 hours |
| FGAT interval | 30 minutes |
| MPAS resolution | Native ~12 km |
| MPAS grid | x1.4096002 |
| Number of cells | 4,096,002 |
| Direct remapping | Disabled |
| Outer loops | 2 |
| Maximum inner iterations | 50 per outer loop |
| Minimizer | DRPCG |
| Requested norm reduction | 1.0e-3 |
| MPAS-JEDI executable status | Successful, rc=0 |

The operational executable was:

    /scratch/lus/arw/intel303/mpas-install/bin/mpasjedi_variational.x

and the variational work directory was:

    /scratch/lus/arw/intel303/run/4d-fgat/12km/variational

---

## Native MPAS geometry

This assimilation was performed directly on the native MPAS forecast
geometry.

The mesh is:

    x1.4096002
    nCells = 4096002

No lower-resolution MPAS-to-MPAS conversion was required for this run.

The direct remapping machinery was therefore disabled and the native
12-km restart trajectory was supplied directly to MPAS-JEDI.

---

## 4D-FGAT trajectory

The six-hour assimilation window spans:

    2026-08-15 21:00 UTC
             |
             | T-3 h
             |
    2026-08-16 00:00 UTC
             |
             | analysis time
             |
    2026-08-16 03:00 UTC
             |
             | T+3 h

The native MPAS restart files used by the workflow were:

### Beginning of window / background

    /scratch/lus/tmp/arw/day/assim/restart.2026-08-15_21:00:00.nc

### Analysis-time state

    /scratch/lus/tmp/arw/day/assim/restart.2026-08-16_00:00:00.nc

### End of window

    /scratch/lus/tmp/arw/day/assim/restart.2026-08-16_03:00:00.nc

The T-3 h state is linked into the JEDI working directory as the principal
background/reference state through names including:

    restart.nc
    init.nc
    background.nc
    templateFields.4096002.nc

The native analysis-time state is retained separately because it later serves
as the complete MPAS carrier file when the final operational analysis is
constructed.

---

## Ensemble configuration

The operational driver supports ensemble-based covariance and 4D ensemble
trajectories.

For this particular example they were disabled:

    USE_FGAT_ENSEMBLE_B=0
    USE_4D_ENSEMBLE_TRAJECTORIES=0

Therefore the background-error covariance used here is the trained static
SABER/BUMP covariance.

No ensemble perturbation trajectory contributes directly to this particular
assimilation example.

---

## Background-error covariance

The covariance model is:

    SABER

with the principal structure:

    StdDev
       |
       v
    BUMP_VerticalBalance
       |
       v
    BUMP_NICAS

The native 12-km covariance resources are located under:

    /scratch/lus/arw/jedi/mpas_only/3.0.3/12km

### NICAS

    /scratch/lus/arw/jedi/mpas_only/3.0.3/12km/NICAS/merge

### Standard deviations

    /scratch/lus/arw/jedi/mpas_only/3.0.3/12km/HDIAGS/merge/mpas.stddev.nc

### Vertical balance

    /scratch/lus/arw/jedi/mpas_only/3.0.3/12km/VBAL

The active covariance variables include:

    stream_function
    velocity_potential
    temperature
    spechum
    surface_pressure
    qc
    qi
    qr
    qs
    qg

The operational workflow validates the covariance/geometry contract before
running the minimization.

The log confirms that the hydrometeor covariance contract passed.

---

## Observation data

Observation input files correspond to analysis time:

    2026081600

The operational observation directory is:

    /scratch/lus/tmp/arw/day/jedi/r12/

The configured observation families include:

- aircraft;
- radiosondes;
- GNSS radio occultation;
- satellite atmospheric-motion vectors;
- ASCAT surface winds;
- AMSU-A radiances;
- MHS radiances;
- IASI radiances.

Representative IODA inputs include:

    aircraft_obs_2026081600.h5
    gnssro_obs_2026081600.h5
    satwind_obs_2026081600.h5
    sondes_obs_2026081600.h5
    ascat_obs_2026081600.h5
    satwnd_obs_2026081600.h5

and radiance files for:

    AMSU-A Metop-B
    AMSU-A Metop-C
    MHS Metop-B
    MHS Metop-C
    IASI Metop-B
    IASI Metop-C

The operational missing-observation policy for this cycle was:

    OBS missing policy=skip

Thus an unavailable optional observation family does not automatically abort
the complete assimilation cycle.

---

## Observation QC

The log includes the complete UFO observation processing and quality-control
diagnostics.

These include, depending on observation type:

- missing-value checks;
- domain checks;
- channel selection;
- bounds checks;
- thinning;
- first-guess checks;
- observation-error assignment;
- H(x) failures;
- final accepted counts.

For example, individual radiance channels show counts for:

    missing values
    out of bounds
    out of domain of use
    removed by thinning
    rejected by first-guess check
    passed observations

The full raw log is intentionally retained because these channel-by-channel
diagnostics are useful when investigating observation or CRTM problems.

---

## Variational bias correction

Variational bias correction is cycled between assimilation cycles.

The persistent bias-correction root is:

    /scratch/lus/tmp/arw/day/assim/varbc

with coefficients under:

    /scratch/lus/tmp/arw/day/assim/varbc/bcoeff

and covariance information under:

    /scratch/lus/tmp/arw/day/assim/varbc/cov

Examples include:

    satbias_amsua_metop-b.nc4
    satbias_cov_amsua_metop-b.nc4

    satbias_amsua_metop-c.nc4
    satbias_cov_amsua_metop-c.nc4

    satbias_mhs_metop-b.nc4
    satbias_cov_mhs_metop-b.nc4

    satbias_mhs_metop-c.nc4
    satbias_cov_mhs_metop-c.nc4

    satbias_iasi_metop-b.nc4
    satbias_cov_iasi_metop-b.nc4

The existing coefficients are read at the beginning of the cycle.

MPAS-JEDI then produces updated coefficient and covariance files in the
variational working directory.

After successful completion, those new files are installed atomically back
into the persistent VarBC directories for use by the following assimilation
cycle.

This example therefore represents a cycled VarBC configuration rather than a
cold-start bias correction.

---

## Cost function and minimization

The assimilation uses:

    cost type: 4D-Var
    minimizer: DRPCG

with:

    outer loops = 2
    maximum inner iterations = 50
    requested norm reduction = 1.0e-3

### Outer loop 1

The first outer-loop minimization used all 50 available DRPCG iterations.

The reported final norm reduction was approximately:

    0.0104656

which corresponds to reducing the residual norm to approximately 1.05% of its
initial value.

### Outer loop 2

The second outer-loop minimization also used all 50 available iterations.

The final reported norm reduction was approximately:

    0.00984905

or approximately 0.985% of the initial residual norm.

### Interpretation

The requested stopping criterion was:

    0.001

while the achieved reductions were approximately:

    outer 1 : 0.0105
    outer 2 : 0.00985

Both minimizations therefore reached the configured 50-iteration limit before
meeting the requested 1.0e-3 criterion.

However, the minimization remained steadily convergent.

The second outer loop reduced the residual by approximately a factor of 100.

This example is therefore useful both as a successful operational run and as
a reference for evaluating whether additional inner iterations should be used
in later tuning experiments.

---

## Observation cost

The log contains nonlinear observation-cost diagnostics for each observation
family and a total nonlinear Jo.

Representative final nonlinear radiance contributions include:

    AMSU-A Metop-B
    AMSU-A Metop-C
    MHS Metop-B
    MHS Metop-C
    IASI Metop-B
    IASI Metop-C

The complete cost values and accepted observation counts should be read from
the raw log when detailed instrument-by-instrument evaluation is required.

---

## Final analysis increments

The final control-variable increment statistics reported by JEDI include:

| Variable | Minimum | Maximum | RMS |
|---|---:|---:|---:|
| temperature | -66.8370 | 33.3835 | 1.40545 K |
| specific humidity | -0.002542 | 0.006730 | 3.04e-4 |
| zonal reconstructed wind | -28.3110 | 37.1755 | 1.23111 m/s |
| meridional reconstructed wind | -31.5924 | 30.4935 | 1.15092 m/s |
| surface pressure | -211.115 | 235.256 | 58.5675 Pa |
| qc | -2.52e-4 | 1.38e-4 | approximately 1e-6 |

Hydrometeor increments for:

    qi
    qr
    qs
    qg

have very small domain-wide RMS values.

The large extrema compared with the RMS indicate localized increments and
should be interpreted spatially rather than as domain-wide instability.

---

## Observation-space diagnostics

The run produces observation-space output and diagnostics that permit
background and analysis departures to be studied.

These diagnostics include observation values, H(x), QC flags, effective
observation errors, departures, and instrument-specific information.

Representative observation-volume diagnostics in the log include several
hundred thousand to several million values for satellite data families.

The log therefore serves as a useful operational reference for expected
observation volumes and QC behavior.

---

## Diagnostic note: satellite wind errors

The raw log contains a very large RMS value in one Satwnd observation-error
diagnostic, with values reaching approximately 1e9.

Such values should not be interpreted as physically meaningful wind errors.

They are consistent with sentinel/disabled/rejected observation-error values
appearing in the diagnostic population.

This did not prevent successful completion of the assimilation, but the raw
Satwnd QC and effective-error fields should be inspected when diagnosing this
observation family.

---

## MPAS-JEDI execution

The executable is:

    /scratch/lus/arw/intel303/mpas-install/bin/mpasjedi_variational.x

The operational variational work directory is:

    /scratch/lus/arw/intel303/run/4d-fgat/12km/variational

The executable completed successfully:

    mpasjedi_variational.x rc=0

The JEDI portion of the workflow ran for approximately 43 minutes.

---

## Intermediate JEDI analysis

The JEDI analysis fields were initially written to:

    /scratch/lus/tmp/arw/day/assim/analysis.2026-08-16_00.00.00.nc

This file contains the JEDI-produced analyzed state variables.

It is not used directly as the final complete MPAS forecast restart.

---

## Construction of the final native MPAS analysis

The operational workflow deliberately preserves the complete native MPAS
analysis-time state.

The native analysis-time restart:

    /scratch/lus/tmp/arw/day/assim/restart.2026-08-16_00:00:00.nc

is first copied to a temporary analysis carrier.

The file is approximately:

    106.968 GiB

and was copied with `dcp` using:

    4 nodes
    32 MPI ranks
    8 ranks per node

The measured copy rate was approximately:

    2.016 GiB/s

and the copy completed in approximately:

    53 seconds

JEDI-analyzed fields are then overlaid onto this complete native restart with
NCO.

The variables copied from the JEDI analysis are:

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

All other native MPAS restart fields remain inherited from the complete
analysis-time model state.

This is important because the MPAS restart contains many physics, surface,
diagnostic, and model-state variables that are not members of the JEDI control
vector.

---

## Final operational analysis

The final native MPAS restart-compatible analysis is:

    /scratch/lus/tmp/arw/day/assim/jedi_analysis.2026-08-16_00.00.00.nc

The log reports successful completion at approximately:

    2026-08-16 13:21:08 UTC

The resulting file is suitable for continuation of the native operational MPAS
forecast because it combines:

    complete native MPAS restart state
                  +
           JEDI analysis fields

rather than replacing the complete restart with a reduced DA-only state.

---

## Workflow summary

The complete example can be represented as:

    native MPAS restart at T-3
              |
              +-------------------------+
              |                         |
              v                         |
       4D-FGAT background               |
                                        |
    native trajectory T-3, T, T+3       |
              |                         |
              v                         |
        observation operators           |
              |                         |
              v                         |
      SABER / StdDev / VBAL / NICAS     |
              |                         |
              v                         |
        DRPCG minimization               |
              |                         |
        two outer loops                  |
              |                         |
              v                         |
        JEDI analysis fields             |
              |                         |
              v                         |
      analysis.2026-08-16_00.00.00.nc
              |
              |
              +---- overlay DA fields ----+
                                        |
                                        v
                    native T0 MPAS restart carrier
                                        |
                                        v
                jedi_analysis.2026-08-16_00.00.00.nc
                                        |
                                        v
                           operational MPAS forecast

---

## Purpose of retaining this log

The full log is intentionally preserved rather than reduced to a short sample.

It provides a real operational reference for:

- expected script initialization;
- runtime variable selection;
- trajectory handling;
- JEDI YAML generation;
- observation configuration;
- CRTM and radiance processing;
- VarBC cycling;
- BUMP/NICAS initialization;
- vertical-balance configuration;
- cost-function evaluation;
- inner-loop convergence;
- outer-loop behavior;
- observation QC;
- increment statistics;
- MPAS-JEDI performance;
- final analysis construction.

It can therefore be compared with future cycles when diagnosing changes in
runtime, convergence, observations, covariance behavior, or analysis
production.

---

## Related repository documentation

Operational driver:

    ../../operational/jedi.oper.sh

Operational JEDI YAML:

    ../../operational/jedi.303.yaml

Operational workflow documentation:

    ../../operational/README.md

Direct MPAS-to-MPAS remapping:

    ../../remap/README.md

B-matrix workflows:

    ../../bmatrix/

---

## Important note

The absolute filesystem paths shown in this example are operational paths from
the system on which the assimilation was run.

They are preserved intentionally because this is a real execution log.

Users reproducing the workflow on another platform must adapt these paths to
their local MPAS, MPAS-JEDI, observation, covariance, and working-directory
installation.
