NMC Sample Preparation for MPAS-JEDI SABER/BUMP

This directory provides the preprocessing workflow used to generate NMC forecast-difference samples for MPAS-JEDI background-error covariance calibration with SABER/BUMP.

The procedure is independent of the MPAS-JEDI release. Version-specific VBAL, HDIAGS and NICAS configurations are maintained separately; the NMC preprocessing described here is concerned only with constructing a consistent population of forecast-difference samples on a given MPAS mesh.

Method

The NMC method estimates background-error statistics from differences between forecasts of different ranges verifying at the same time:

[
\delta x(t_v) = x_{\mathrm{long}}(t_v) - x_{\mathrm{short}}(t_v)
]

where (t_v) is the common verification time.

For the dataset used to develop this workflow, the actual forecast ranges were 12 h and 24 h. Historical processing names are retained internally:

actual +12 h forecast  -> technical F24
actual +24 h forecast  -> technical F48

Consequently, the processed states and perturbations are named:

FULL_f24.nc
FULL_f48.nc
PTB_f48mf24.nc

with

\mathrm{FULL}_{f48}

\mathrm{FULL}_{f24}.
]

The actual short and long forecast ranges are configurable. The F24/F48 names are therefore technical labels rather than a restriction of the methodology.

Only forecasts verifying at the same time are paired. Both members of a pair must use the same MPAS horizontal mesh and vertical discretization.

Construction of the MPAS-JEDI control variables

Native MPAS forecast output does not directly contain every variable required by the control vector used during SABER/BUMP calibration. Before differencing, each forecast is therefore transformed into a complete state containing the required analysis variables.

The principal constructed variables are:

stream_function
velocity_potential
temperature
spechum
surface_pressure

Native reconstructed winds, relative humidity and hydrometeors are retained when required by the covariance configuration:

uReconstructZonal
uReconstructMeridional
relhum
qc
qi
qr
qs
qg

Temperature

MPAS potential temperature is converted to physical temperature using pressure:

[
T =
\theta
\left(\frac{p}{100000}\right)^{2/7}.
]

When total pressure is not explicitly available, it is reconstructed as

[
p = p_{\mathrm{base}} + p',
]

from the MPAS fields pressure_base and pressure_p.

The resulting variable is stored as temperature.

Specific humidity

The native MPAS water-vapour mixing ratio qv is converted to specific humidity according to

[
q = \frac{q_v}{1+q_v}.
]

The resulting variable is stored as spechum.

Stream function and velocity potential

The horizontal wind transformation is the main diagnostic step required before the NMC samples can be used by the MPAS-JEDI control vector.

Native MPAS provides reconstructed horizontal wind components:

uReconstructZonal
uReconstructMeridional

whereas the covariance training uses the rotational and divergent wind representation:

stream_function
velocity_potential

These variables represent the Helmholtz decomposition of the horizontal wind:

\mathbf{k}\times\nabla\psi
+
\nabla\chi ,
]

where (\psi) is the stream function and (\chi) is the velocity potential.

Technical transformation

The conversion is performed by the MPAS-JEDI preprocessing utility used by this workflow. The native unstructured MPAS wind field is handled through an intermediate regular latitude/longitude representation.

Precomputed interpolation/remapping weights are used for the transformations associated with the native MPAS mesh and the intermediate regular grid. The workflow therefore follows the conceptual sequence

MPAS native mesh
      |
      | precomputed interpolation/remapping weights
      v
regular latitude/longitude representation
      |
      | wind diagnostic transformation
      v
stream function / velocity potential
      |
      | precomputed interpolation/remapping weights
      v
MPAS native mesh

The regular-grid definition used in the original preparation is identified by:

latlon_0p1

corresponding to the 0.1-degree intermediate grid used by the conversion workflow.

The interpolation weights are stored separately from the NMC samples and are reused for all forecast states on the same MPAS mesh. Their location and grid prefix are supplied to the preprocessing through WEIGHTS_DIR and LATLON_PREFIX.

The weights must correspond to the exact MPAS mesh being processed. Changing the MPAS mesh requires the corresponding interpolation/remapping weights to be generated or supplied.

This intermediate transformation is used only to construct the diagnostic wind control variables. The final NMC subtraction is performed between complete states represented on the same native MPAS geometry; no interpolation between different MPAS meshes is introduced during the NMC differencing.

Additional fields

surface_pressure, reconstructed zonal and meridional winds, and relative humidity are retained from the corresponding native MPAS forecast.

When required by the B-matrix configuration and available in the native forecast, the hydrometeor fields

qc
qi
qr
qs
qg

are also included in the processed states and therefore in the resulting NMC perturbations.

This permits covariance calibration for a control vector extending beyond the traditional dynamical and thermodynamic variables.

Formation of the NMC samples

After construction of the required variables, each forecast pair provides two complete states:

FULL_f24.nc
FULL_f48.nc

corresponding to the configured short- and long-range forecasts verifying at the same time.

The perturbation is then calculated directly as

PTB_f48mf24.nc = FULL_f48.nc - FULL_f24.nc

on the native MPAS geometry.

Only complete pairs are retained.

The accepted perturbations are collected as sequential symbolic links:

PTB_f48mf24_001.nc
PTB_f48mf24_002.nc
...
PTB_f48mf24_NNN.nc

These files constitute the sample population supplied to SABER/BUMP.

Processing chain

Native MPAS forecasts
        |
        v
Select short- and long-range forecasts
with a common verification time
        |
        v
Construct required control variables
        |
        +-- theta + pressure -> temperature
        |
        +-- qv -> spechum
        |
        +-- U/V -> stream_function
        |         velocity_potential
        |
        +-- retain surface pressure,
            reconstructed winds, RH
            and required hydrometeors
        |
        v
Complete MPAS states
FULL_f24.nc / FULL_f48.nc
        |
        v
Long-range minus short-range forecast
        |
        v
PTB_f48mf24.nc
        |
        v
PTB_f48mf24_001.nc ... PTB_f48mf24_NNN.nc
        |
        v
VBAL -> HDIAGS -> NICAS
        |
        v
SABER/BUMP background-error covariance

Implementation

The implementation is provided by:

scripts/prepare_nmc_samples.sh
scripts/collect_samples.sh
scripts/common_runtime.sh

prepare_nmc_samples.sh performs the forecast selection, diagnostic-variable construction and NMC differencing.

collect_samples.sh assembles the accepted perturbations into the numbered sample population used by the subsequent calibration stages.

common_runtime.sh provides the runtime definitions required by the preprocessing utilities.

Machine-specific paths, Slurm resources and operational implementation details are intentionally kept in the scripts rather than duplicated in this document.
