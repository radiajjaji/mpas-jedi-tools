# MPAS-JEDI Tools and Native-MPAS B-Matrix Workflows

Reproducible build configurations, operational workflows, and
background-error covariance generation tools for MPAS-JEDI,
SABER/BUMP and MPAS-Atmosphere.

## Native MPAS Background-Error Covariance Generation

This repository documents a successful end-to-end generation and
operational integration of MPAS-JEDI/SABER background-error
covariance matrices derived from **native MPAS-Atmosphere forecast
data**.

The training data used in these workflows originate directly from
MPAS-Atmosphere forecasts produced by an operational MPAS forecasting
system. No intermediate conversion from another forecast model is
required to construct the covariance-training dataset.

The complete methodology has been successfully implemented at
multiple MPAS horizontal resolutions:

| Resolution | Status | Main covariance components |
|------------|--------|----------------------------|
| 12 km | Successfully generated and operationally used | VBAL, HDIAGS, NICAS, BUMPLOC |
| 24 km | Successfully generated | VBAL, HDIAGS, NICAS, BUMPLOC |
| 30 km | Successfully generated | VBAL, HDIAGS, NICAS, BUMPLOC |

## Workflow

Native operational MPAS forecasts
        |
        v
Forecast/ensemble samples
        |
        v
       VBAL
        |
        v
      HDIAGS
        |
        v
       NICAS
        |
        +---- BUMP localization
        |
        v
   MPAS-JEDI DA

The objective is to maintain a covariance-training workflow that
remains inside the MPAS model system from the original atmospheric
forecast samples through the final covariance representation.

## B-Matrix Resolutions

### 12 km

The 12-km case is generated directly from native high-resolution
operational MPAS forecasts.

Available components include:

- Vertical balance coefficients (VBAL)
- Standard deviations and horizontal/vertical diagnostics (HDIAGS)
- NICAS covariance representation
- BUMP/NICAS localization

### 24 km

The same native-MPAS methodology was successfully extended to a
24-km MPAS mesh.

The repository provides the VBAL, HDIAGS, NICAS, merge/tuning and
localization workflows used to generate the corresponding covariance.

### 30 km

The workflow was also successfully implemented at 30-km resolution,
demonstrating that the covariance-generation procedure can be applied
to multiple MPAS meshes.

## Repository Layout

build/
  intel303/       Intel MPAS-JEDI build configuration and patches

spack/
  site/           Site-specific Spack-stack configuration
  spack.yaml      Reproducible Spack environment
  spack.lock
  switch_to_oper.sh

operational/
  jedi.oper.sh    Operational MPAS-JEDI driver
  jedi.303.yaml   Operational MPAS-JEDI configuration

bmatrix/
  3.0.3/
    12km/         Native 12-km covariance workflow
    24km/         24-km covariance workflow
    30km/         30-km covariance workflow

docs/             Technical notes and documentation

## Large Covariance Data

The complete covariance datasets are too large for normal GitHub
storage, especially the distributed local NICAS representation.

This repository therefore contains:

- reproducible generation scripts;
- operational configuration;
- build and software-environment configuration;
- metadata and inventories for the generated covariance datasets;
- selected covariance products where practical.

Complete generated datasets can be distributed separately using
large scientific-data storage.

## Operational NICAS Representation

The operational MPAS-JEDI configuration uses the distributed local
NICAS representation rather than only a single global NICAS file.

Consequently, a complete operational covariance dataset consists of
many rank-local NetCDF files in addition to the VBAL, HDIAGS and
localization components.

## Author

**Radi Ajjaji**

Numerical Weather Prediction | Data Assimilation | HPC | AI Weather Models

LinkedIn:
https://www.linkedin.com/in/radi-ajjaji-10008071

## Upstream Projects

This work builds on the MPAS-Atmosphere, MPAS-JEDI, JEDI,
SABER and BUMP software ecosystems.

The scripts and configurations in this repository document
independent integration and operational development around those
projects and are not an official upstream distribution.

See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
