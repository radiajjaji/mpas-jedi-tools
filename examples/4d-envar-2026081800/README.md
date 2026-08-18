# MPAS-JEDI Operational 4D-EnVar Assimilation — Execution Report

## Analysis cycle: 2026-08-18 00 UTC

This directory contains the complete execution log from a successful
operational **MPAS-JEDI 4D-EnVar** data-assimilation cycle.

The run demonstrates the complete reduced-resolution assimilation strategy used
by the operational workflow:

```text
Native 12-km MPAS forecast
          |
          v
Direct MPAS-to-MPAS remapping
     12 km -> 24 km
          |
          v
24-km trajectory preparation
          |
          v
11-member 24-km ensemble
          |
          v
Hybrid MPAS-JEDI 4D-EnVar
  75% static B + 25% ensemble B
          |
          v
24-km analyzed state
          |
          v
Direct return remapping
     24 km -> 12 km
          |
          v
Native-state reconstruction
          |
          v
Final operational 12-km analysis
```

The complete raw execution log associated with this report is:

```text
jedi.oper303.out
```

The final operational analysis produced by the workflow is:

```text
/scratch/lus/tmp/arw/day/assim/jedi_analysis.2026-08-18_00.00.00.nc
```

---

# 1. Run summary

| Property | Value |
|---|---|
| Analysis date | 2026-08-18 |
| Analysis time | 00:00 UTC |
| Assimilation method | 4D-EnVar |
| Native MPAS resolution | ~12 km |
| Native MPAS mesh | `x1.4096002` |
| Native number of cells | 4,096,002 |
| Assimilation resolution | ~24 km |
| Assimilation mesh | `x1.1024002` |
| Assimilation number of cells | 1,024,002 |
| Assimilation window | 2026-08-17 21 UTC → 2026-08-18 03 UTC |
| Window length | 6 hours |
| Ensemble members | 11 |
| Ensemble forecast length | 6 hours |
| Ensemble output interval | 3 hours |
| Static covariance weight | 0.75 |
| Ensemble covariance weight | 0.25 |
| Outer loops | 2 |
| Maximum inner iterations | 50 |
| Minimizer | DRPCG |
| Linear model | Identity |
| Requested gradient/residual reduction | `1.0e-3` |
| MPAS-JEDI executable | `mpasjedi_variational.x` |
| MPAS-JEDI return code | `0` |
| Final geometry | Native 12 km |
| Overall result | **SUCCESS** |

---

# 2. Operational architecture

This cycle exercised the complete operational reduced-resolution
data-assimilation architecture.

```text
                         Native MPAS
                     12-km x1.4096002
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
          T - 3 hours         T          T + 3 hours
          17 Aug 21Z      18 Aug 00Z     18 Aug 03Z
              |               |               |
              +---------------+---------------+
                              |
                              v
                  Direct horizontal remapping
                       12 km -> 24 km
                              |
                              v
                      24-km trajectory
                              |
                   +----------+----------+
                   |                     |
                   |                     v
                   |              Ensemble check
                   |                     |
                   |                     v
                   |          Generate 11-member ensemble
                   |                     |
                   +----------+----------+
                              |
                              v
                      Hybrid 4D-EnVar
                              |
                 +------------+------------+
                 |                         |
                 v                         v
             Static B                 Ensemble B
                75%                       25%
                 |                         |
                 +------------+------------+
                              |
                              v
                     MPAS-JEDI analysis
                              |
                              v
                Complete 24-km analysis carrier
                              |
                              v
                     Direct return remap
                       24 km -> 12 km
                              |
                              v
              Preserve native non-DA model state
                              |
                              v
                 FINAL NATIVE 12-km ANALYSIS
```

This design allows the computationally expensive variational analysis to run
on a reduced MPAS geometry while retaining the operational forecast on the
native 12-km mesh.

---

# 3. Native forecast geometry

The operational MPAS forecast geometry is:

```text
Mesh        : x1.4096002
nCells      : 4096002
Resolution  : approximately 12 km
```

The native mesh files are maintained under the operational MPAS mesh tree,
for example:

```text
/scratch/lus/arw/model/src/mpas/meshes/12/
```

The native MPAS forecast remains the authoritative model state before and
after assimilation.

---

# 4. Variational analysis geometry

For this experiment, MPAS-JEDI was configured to perform the variational
analysis on the lower-resolution 24-km mesh:

```text
Mesh        : x1.1024002
nCells      : 1024002
Resolution  : approximately 24 km
```

The reduced analysis geometry lowers memory use and computational cost for:

```text
observation operators
SABER covariance application
ensemble covariance application
outer-loop nonlinear evaluations
inner-loop minimization
```

while the analysis is subsequently returned to the native 12-km geometry.

---

# 5. Assimilation time window

The central analysis time was:

```text
2026-08-18 00:00:00 UTC
```

The six-hour assimilation window was:

```text
2026-08-17 21:00:00 UTC     T - 3 h
2026-08-18 00:00:00 UTC     T
2026-08-18 03:00:00 UTC     T + 3 h
```

The corresponding native MPAS restart files were:

```text
/scratch/lus/tmp/arw/day/assim/restart.2026-08-17_21:00:00.nc
/scratch/lus/tmp/arw/day/assim/restart.2026-08-18_00:00:00.nc
/scratch/lus/tmp/arw/day/assim/restart.2026-08-18_03:00:00.nc
```

These three files provide the native atmospheric trajectory from which the
24-km assimilation trajectory was constructed.

---

# 6. Direct 12-km -> 24-km MPAS remapping

The native trajectory was converted directly between MPAS meshes.

The remapper executable was:

```text
/scratch/lus/arw/model/src/util/mpas_remap_state/mpas_remap_state
```

The remapping operation was:

```text
SOURCE
x1.4096002
4096002 cells
      |
      | sparse direct MPAS remapping
      v
TARGET
x1.1024002
1024002 cells
```

The target restart template was:

```text
restart.24km.x1.1024002.template.nc
```

The remapper uses precomputed sparse source-to-target weights.

Two classes of weight files are used:

```text
smooth weights
conservative weights
```

The operational log reports:

```text
Starting 3 parallel target-resolution direct MPAS remaps
Each remap: 1 node, 64 OpenMP threads
```

The three trajectory times were therefore converted concurrently:

```text
restart.2026-08-17_21:00:00.nc
restart.2026-08-18_00:00:00.nc
restart.2026-08-18_03:00:00.nc
```

to corresponding 24-km states.

Detailed documentation of the direct remapper is available at:

```text
../../remap/README.md
```

---

# 7. Ensemble requirement

This 4D-EnVar configuration required an ensemble on the same 24-km
assimilation geometry.

The expected ensemble directory was:

```text
/scratch/lus/tmp/arw/day/ens/24km/r12/2026081800
```

During preparation, the workflow detected that the required ensemble did not
exist or was incomplete.

The log reported:

```text
Ensemble directory does not exist
Required ensemble is incomplete
A clean ensemble will be generated before MPAS-JEDI analysis
```

The workflow therefore automatically generated a new ensemble rather than
allowing the assimilation to proceed with stale or incomplete ensemble input.

---

# 8. Ensemble generation

The generated ensemble configuration was:

```text
Number of members     : 11
Resolution            : 24 km
Forecast length       : PT6H
Output frequency      : PT3H
```

The ensemble generation started at approximately:

```text
2026-08-18 11:30:55 UTC
```

and completed at approximately:

```text
2026-08-18 11:54:21 UTC
```

Elapsed time:

```text
00:23:26
```

The newly generated ensemble provided the flow-dependent covariance component
for the subsequent hybrid 4D-EnVar assimilation.

---

# 9. Hybrid covariance formulation

The run combined a trained static covariance with ensemble-derived
flow-dependent covariance.

The weights were:

```text
Static covariance weight    : 0.75
Ensemble covariance weight  : 0.25
```

Conceptually:

```text
                    Hybrid B
                       |
               +-------+-------+
               |               |
               v               v
           Static B        Ensemble B
              75%              25%
```

This allows the analysis to retain the robustness of a trained static
background-error covariance while adding flow-dependent information from the
current ensemble.

---

# 10. Static B-matrix resources

The static covariance resources were taken from:

```text
/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/
```

Important components include:

```text
NICAS/merge/
VBAL/
HDIAGS/merge/mpas.stddev.nc
```

These provide:

```text
horizontal localization/correlation structure
vertical balance relationships
standard deviations
```

The associated B-matrix generation and calibration workflows are maintained
under:

```text
../../bmatrix/
```

---

# 11. Ensemble localization

The flow-dependent covariance localization resources were read from:

```text
/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/BUMPLOC
```

with localization prefix:

```text
mpas_bumploc
```

The ensemble component therefore uses a calibrated localization rather than
unlocalized member perturbations.

---

# 12. Observation preparation

The observations used by this assimilation were prepared by the operational
JEDI observation workflow:

```text
../../operational/jedi_obs.sh
```

A documented real observation-preparation execution is available under:

```text
../obs-preparation-2026081812/
```

The observation preparation workflow downloads NCEP BUFR data, validates
observation-slot dates and converts supported observation types to IODA HDF5.

---

# 13. Observation location

The operational IODA observation files used by the assimilation were located
under:

```text
/scratch/lus/tmp/arw/day/jedi/r12/
```

for analysis time:

```text
2026081800
```

The workflow allows unavailable optional observation types to be skipped with:

```text
JEDI_OBS_MISSING_POLICY=skip
```

rather than terminating the entire assimilation cycle.

---

# 14. Observation families

The active observation configuration included conventional, wind,
scatterometer, microwave and hyperspectral observations.

Representative observation families were:

```text
radiosonde
aircraft
GNSS radio occultation
surface observations
satellite winds
ASCAT
AMSU-A Metop-B
AMSU-A Metop-C
MHS Metop-B
MHS Metop-C
IASI Metop-B
IASI Metop-C
```

The raw execution log contains the detailed UFO processing information,
including observation counts, QC decisions, channel usage and observation
errors.

---

# 15. Variational bias correction

Satellite radiance bias correction was operated in cycling mode.

Persistent bias-correction resources were located under:

```text
/scratch/lus/tmp/arw/day/assim/varbc/
```

with coefficients under:

```text
/scratch/lus/tmp/arw/day/assim/varbc/bcoeff/
```

and covariance information under:

```text
/scratch/lus/tmp/arw/day/assim/varbc/cov/
```

The log confirms cycling for instruments including:

```text
VarBC amsua_metop-b : cycle
VarBC amsua_metop-c : cycle
VarBC mhs_metop-b   : cycle
VarBC mhs_metop-c   : cycle
VarBC iasi_metop-b  : cycle
```

Thus existing bias information was propagated between operational cycles where
available.

---

# 16. MPAS-JEDI executable

The variational executable was:

```text
/scratch/lus/arw/intel303/mpas-install/bin/mpasjedi_variational.x
```

The run invocation was equivalent to:

```bash
mpasjedi_variational.x jedi.yaml
```

The executable started at approximately:

```text
2026-08-18 11:54:41 UTC
```

and completed at approximately:

```text
2026-08-18 12:10:28 UTC
```

Elapsed time:

```text
00:15:47
```

The executable returned:

```text
mpasjedi_variational.x rc=0
```

confirming successful completion of the variational analysis.

---

# 17. Variational configuration

The principal minimization configuration was:

```text
Assimilation mode              : 4D-EnVar
Outer-loop count               : 2
Maximum inner iterations       : 50
Gradient norm reduction target : 1.0e-3
Minimizer                      : DRPCG
Linear model                   : Identity
```

The log confirms completion of both requested outer loops:

```text
Variational: incremental assimilation done 2 iterations.
```

---

# 18. Outer loops

The assimilation used two nonlinear outer loops.

Conceptually:

```text
Background
    |
    v
Outer loop 1
    |
    +--> nonlinear H(x)
    |
    +--> tangent/linearized minimization
    |
    v
Updated state
    |
    v
Outer loop 2
    |
    +--> recomputed nonlinear H(x)
    |
    +--> second inner minimization
    |
    v
Final analysis
```

Using multiple outer loops permits the nonlinear observation operators and
model-state-dependent quantities to be reevaluated around an improved state.

---

# 19. Inner-loop minimization

The minimizer used was:

```text
DRPCG
```

The configured maximum was:

```text
50 inner iterations
```

The second minimization reached:

```text
DRPCG end of iteration 50
```

with approximately:

```text
Quadratic J = 1,470,609.89
Jb          =   108,331.09
JoJc        = 1,362,278.79
```

Reported residual-norm reductions were approximately:

```text
Outer loop 1 : 0.091579
Outer loop 2 : 0.064377
```

The requested reduction was:

```text
1.0e-3
```

Therefore the minimization stopped because the configured maximum number of
inner iterations was reached, not because the requested convergence criterion
had been satisfied.

---

# 20. Minimization efficiency

The quadratic cost continued decreasing near the end of the second inner
loop.

Representative values were:

```text
Iteration 40 : J = 1,525,076.81
Iteration 45 : J = 1,494,010.96
Iteration 50 : J = 1,470,609.89
```

This indicates that the minimizer was still making useful progress when the
50-iteration ceiling was reached.

A controlled experiment with:

```text
JEDI_NINNER=60
```

or:

```text
JEDI_NINNER=70
```

may therefore be useful for determining whether additional convergence
provides a meaningful improvement relative to the additional computational
cost.

No operational change should be made from this single experiment without
comparison against additional cycles.

---

# 21. Cost-function evolution

Representative nonlinear cost values during the assimilation included:

```text
Nonlinear J = 4,175,129.06
Nonlinear J = 2,991,862.65
```

showing substantial reduction during the incremental assimilation.

A later diagnostic evaluation reported:

```text
Nonlinear J = 5,722,936.47
```

This later value belongs to a different nonlinear diagnostic stage and should
not be interpreted as directly equivalent to the quadratic inner-loop cost.

The DRPCG quadratic-cost sequence is the more appropriate diagnostic for
evaluating inner-loop minimization efficiency.

---

# 22. Analysis increment RMS

Representative final RMS analysis increments were:

| Variable | RMS increment |
|---|---:|
| Temperature | 1.266 K |
| Specific humidity | 3.29e-4 |
| Zonal reconstructed wind | 0.491 m s-1 |
| Meridional reconstructed wind | 0.481 m s-1 |
| Surface pressure | 36.09 Pa |
| Cloud water `qc` | 9e-6 |
| Cloud ice `qi` | 3e-6 |
| Rain water `qr` | 2e-6 |
| Snow `qs` | 5e-6 |
| Graupel `qg` | 1e-6 |

For the principal dynamical fields:

```text
Temperature RMS       : approximately 1.27 K
Horizontal wind RMS   : approximately 0.5 m/s
Surface pressure RMS  : approximately 36 Pa
                       : approximately 0.36 hPa
```

These values characterize the domain-wide magnitude of the correction applied
to the background state.

---

# 23. Moisture and hydrometeor increments

The assimilation included moisture and hydrometeor control/state variables.

Representative RMS increments were small:

```text
qv  : 3.29e-4
qc  : 9e-6
qi  : 3e-6
qr  : 2e-6
qs  : 5e-6
qg  : 1e-6
```

These statistics provide an important check that the moisture analysis did not
introduce unrealistically large domain-wide hydrometeor perturbations.

---

# 24. Observation-space diagnostics

Representative final bias-corrected departure RMS values included:

| Observation family | RMS departure |
|---|---:|
| Radiosonde | 2.15 |
| Aircraft | 4.19 |
| GNSS-RO | 3.69 |
| Surface pressure | 439.6 Pa |
| Satellite wind stream | 4.67 m s-1 |
| Satellite wind stream | 2.78 m s-1 |
| AMSU-A Metop-B | 13.93 K |
| AMSU-A Metop-C | 6.81 K |
| MHS Metop-B | 5.14 K |
| MHS Metop-C | 4.81 K |
| IASI Metop-B | 3.43 K |
| IASI Metop-C | 3.43 K |
| ASCAT | 2.27 m s-1 |

These numbers should be interpreted together with:

```text
observation counts
accepted counts
QC flags
channel selection
observation-error assignments
thinning
VarBC
instrument-specific cost
```

all of which are available in the raw execution log.

---

# 25. IASI contribution to the cost function

IASI represented a particularly large contribution to the nonlinear
observation cost.

Approximate values reported by the run were:

```text
IASI Metop-C : Jo ~ 2.255 x 10^6
IASI Metop-B : Jo ~ 2.133 x 10^6
```

The total reported nonlinear observation cost was approximately:

```text
Total nonlinear Jo ~ 5.723 x 10^6
```

Thus the two IASI datasets represented a substantial fraction of the total
observation contribution.

This warrants further investigation of:

```text
number of IASI observations
accepted IASI observations
active channels
channel-specific departures
observation errors
thinning
quality control
VarBC coefficients
VarBC evolution
```

before any operational tuning decision is made.

---

# 26. JEDI analysis output

MPAS-JEDI first produced the analyzed variables on the 24-km analysis
geometry.

Because the DA control/state does not contain every field required by a
complete MPAS restart, the workflow subsequently constructs a complete target
analysis carrier.

The resulting complete 24-km analysis file was:

```text
analysis.complete.24km.2026081800.nc
```

Conceptually:

```text
Complete 24-km state
         +
JEDI analyzed variables
         |
         v
analysis.complete.24km.2026081800.nc
```

This complete state can then safely be passed through the direct return
remapper.

---

# 27. Why a complete analysis carrier is necessary

An MPAS restart contains considerably more information than the variables
directly controlled by the DA system.

Examples include:

```text
surface state
land-model state
physics state
diagnostic state
static fields
non-DA atmospheric fields
accumulators
restart bookkeeping
```

For that reason, the workflow does not treat a reduced JEDI analysis as a
standalone complete restart.

Instead, analyzed variables are inserted into a complete MPAS state before
return remapping.

---

# 28. Direct 24-km -> 12-km return remapping

After successful completion of the variational analysis, the complete 24-km
analysis was remapped to the native 12-km mesh.

The return operation was:

```text
SOURCE
x1.1024002
1024002 cells
      |
      | direct MPAS-to-MPAS remapping
      v
TARGET
x1.4096002
4096002 cells
```

Source file:

```text
analysis.complete.24km.2026081800.nc
```

Intermediate native-resolution analysis carrier:

```text
restart.analysis.12km.2026081800.nc
```

Approximate timing:

```text
Start : 2026-08-18 12:11:45 UTC
End   : 2026-08-18 12:18:18 UTC

Elapsed: 00:06:33
```

---

# 29. Return-remap performance

The return-remapping stage required approximately:

```text
6 minutes 33 seconds
```

even though the remapper was configured to request:

```text
OMP_NUM_THREADS=64
--cpus-per-task=64
```

The remapping completed successfully, but this timing is slower than the best
standalone remapper timings obtained during development.

Potential performance factors to evaluate include:

```text
Slurm step CPU allocation
CPU affinity
OpenMP placement
memory bandwidth
NetCDF I/O
filesystem contention
simultaneous Lustre traffic
```

This is a performance issue rather than a scientific failure of the remapping
operation.

---

# 30. Preservation of native non-DA fields

The final analysis construction deliberately preserves the complete native
12-km analysis-time model state.

The workflow reports:

```text
Overwriting native 12-km analyzed fields from direct-remapped analysis carrier
```

and:

```text
Non-DA fields preserved from native analysis-time background:
restart.2026-08-18_00:00:00.nc
```

Therefore the final reconstruction is:

```text
Native 12-km analysis-time restart
                 |
                 | preserve full native state
                 v
          Native analysis carrier
                 ^
                 |
         overwrite only
      DA-controlled variables
                 |
                 |
      remapped 24-km analysis
```

This avoids unnecessarily replacing native surface, physics and other
non-control-vector fields with values interpolated through the 24-km analysis
geometry.

---

# 31. Final operational analysis

The complete workflow finished at approximately:

```text
2026-08-18 12:24:47 UTC
```

The log reports:

```text
Final native 12-km analysis created through direct MPAS return remap
```

The final analysis file is:

```text
/scratch/lus/tmp/arw/day/assim/jedi_analysis.2026-08-18_00.00.00.nc
```

This is the final native-resolution MPAS analysis produced by the cycle.

---

# 32. Timing report

Approximate major-stage timing from the operational log:

| Stage | Start UTC | End UTC | Elapsed |
|---|---:|---:|---:|
| Ensemble generation | 11:30:55 | 11:54:21 | 23m 26s |
| MPAS-JEDI variational analysis | 11:54:41 | 12:10:28 | 15m 47s |
| 24-km → 12-km return remap | 12:11:45 | 12:18:18 | 6m 33s |
| Final native analysis available | — | 12:24:47 | — |

The largest single preparation cost was ensemble generation because an
existing valid 24-km ensemble was not available for the cycle.

---

# 33. Successful workflow components

The run successfully exercised all of the following:

```text
[OK] Native 12-km MPAS trajectory availability

[OK] Three-time assimilation trajectory
     T-3 h
     T
     T+3 h

[OK] Direct MPAS-to-MPAS state remapping

[OK] Native 12-km -> analysis 24-km conversion

[OK] Three parallel forward remaps

[OK] 64-thread OpenMP remapper requests

[OK] Reduced-resolution 24-km trajectory creation

[OK] Ensemble availability checking

[OK] Detection of missing/incomplete ensemble

[OK] Automatic clean ensemble generation

[OK] 11-member ensemble

[OK] Six-hour ensemble forecast

[OK] Three-hourly ensemble state availability

[OK] Hybrid 4D-EnVar covariance

[OK] 75% static covariance contribution

[OK] 25% ensemble covariance contribution

[OK] NICAS

[OK] Vertical balance

[OK] Standard-deviation fields

[OK] BUMP ensemble localization

[OK] Conventional observations

[OK] GNSS-RO observations

[OK] Satellite wind observations

[OK] ASCAT observations

[OK] AMSU-A radiances

[OK] MHS radiances

[OK] IASI radiances

[OK] Radiance VarBC cycling

[OK] Two nonlinear outer loops

[OK] DRPCG minimization

[OK] Successful MPAS-JEDI execution

[OK] Complete 24-km analysis reconstruction

[OK] Direct 24-km -> 12-km analysis remapping

[OK] Native non-DA field preservation

[OK] Native 12-km final-analysis generation
```

---

# 34. Scientific and performance findings

The run completed successfully, but it also identifies several useful areas for
future study.

## 34.1 Inner-loop convergence

The inner minimization reached the configured limit of:

```text
50 iterations
```

without reaching:

```text
1.0e-3
```

residual reduction.

The quadratic cost was still decreasing at iteration 50.

A controlled sensitivity test using:

```text
60 inner iterations
```

and:

```text
70 inner iterations
```

would help determine whether more iterations significantly improve the
analysis.

---

## 34.2 IASI contribution

IASI Metop-B and Metop-C contributed a large fraction of the nonlinear
observation cost.

This does not automatically indicate a problem, because the IASI observation
volume may also be very large.

The correct investigation should examine:

```text
active channels
total counts
accepted counts
departures by channel
effective observation errors
QC rejection
thinning
VarBC
cost contribution per channel
```

before changing the configuration.

---

## 34.3 Remapping performance

The return remap required:

```text
00:06:33
```

despite a nominal 64-thread configuration.

This should be profiled independently from the scientific validity of the
analysis.

The remapper itself completed successfully.

---

# 35. Overall technical assessment

This cycle represents a successful end-to-end test of the operational
reduced-resolution hybrid MPAS-JEDI 4D-EnVar system.

The important result is that the entire chain:

```text
native forecast
      |
      v
forward remapping
      |
      v
ensemble generation
      |
      v
hybrid 4D-EnVar
      |
      v
analysis
      |
      v
return remapping
      |
      v
native-state reconstruction
```

completed successfully.

The MPAS-JEDI variational executable returned:

```text
rc=0
```

and the final native analysis was created at:

```text
/scratch/lus/tmp/arw/day/assim/jedi_analysis.2026-08-18_00.00.00.nc
```

The remaining questions concern:

```text
minimization tuning
radiance diagnostics
ensemble-generation cost
remapping performance
```

rather than failure of the assimilation architecture.

---

# 36. Files in this example

A typical directory listing is:

```console
$ ls -lh examples/4d-envar-2026081800/

total ...
-rw-r--r-- 1 user group  ... README.md
-rw-r--r-- 1 user group  ... jedi.oper303.out
```

The files are:

```text
README.md
    This technical report.

jedi.oper303.out
    Complete raw operational execution log.
```

The raw log is intentionally retained so individual JEDI, UFO, SABER, BUMP,
VarBC and MPAS diagnostics can be traced back to their original execution
messages.

---

# 37. Related repository files

Operational assimilation driver:

```text
../../operational/jedi.oper.sh
```

Operational JEDI YAML:

```text
../../operational/jedi.303.yaml
```

Operational observation preparation:

```text
../../operational/jedi_obs.sh
```

Operational workflow documentation:

```text
../../operational/README.md
```

Direct MPAS-to-MPAS remapper source:

```text
../../remap/src/mpas_remap_state_v3_restart_fastio.F90
```

Remapper documentation:

```text
../../remap/README.md
```

Weight-generation utility:

```text
../../remap/generate_mpas_weights_robust.slurm
```

B-matrix workflows:

```text
../../bmatrix/
```

Observation-preparation example:

```text
../obs-preparation-2026081812/
```

The separate 4D-FGAT example is maintained independently under:

```text
../4d-fgat-2026081600/
```

---

# 38. Reproducibility note

The filesystem paths in this report and in `jedi.oper303.out` are the actual
operational paths used on the HPE Cray system where this assimilation was run.

Examples include:

```text
/scratch/lus/arw/model/
/scratch/lus/arw/jedi/
/scratch/lus/tmp/arw/day/
/scratch/lus/arw/intel303/
```

They are deliberately retained because this directory documents a real
operational execution rather than a synthetic example.

Users reproducing the workflow on another HPC system must adapt:

```text
MPAS installation paths
MPAS-JEDI installation paths
mesh locations
observation locations
B-matrix locations
VarBC locations
ensemble directories
remapping weights
target templates
Slurm resources
MPI layout
OpenMP layout
filesystem paths
```

to their local environment.

---

# 39. Conclusion

This operational experiment demonstrates that a native 12-km MPAS forecast can
be assimilated efficiently using a reduced 24-km hybrid 4D-EnVar geometry and
then returned to the native forecast grid.

The complete sequence:

```text
12-km MPAS
     |
     v
24-km trajectory
     |
     v
11-member 24-km ensemble
     |
     v
Hybrid 4D-EnVar
     |
     v
24-km analysis
     |
     v
12-km return remap
     |
     v
Native-state reconstruction
     |
     v
jedi_analysis.2026-08-18_00.00.00.nc
```

completed successfully.

The run therefore provides a useful reference case for future comparison of:

```text
assimilation convergence
observation usage
VarBC behaviour
B-matrix performance
ensemble influence
analysis increments
runtime performance
remapping efficiency
```

and for diagnosing subsequent operational MPAS-JEDI cycles.
