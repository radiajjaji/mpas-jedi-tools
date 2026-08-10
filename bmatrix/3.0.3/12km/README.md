# Native-MPAS B-Matrix — 12 km

## Status

Successfully generated and used in the operational MPAS-JEDI workflow.

## Data origin

The covariance training samples originate from native
MPAS-Atmosphere forecasts produced by the operational MPAS system.

No conversion from another forecast model is required to construct
the training dataset.

## Resolution

- Horizontal resolution: approximately 12 km
- Native operational MPAS mesh
- Covariance framework: SABER/BUMP

## Components

The generated covariance includes:

- VBAL — vertical balance
- HDIAGS — standard deviations and correlation diagnostics
- NICAS — covariance representation
- BUMPLOC — localization

## Operational representation

The operational MPAS-JEDI configuration uses the distributed local
NICAS representation.

The complete covariance therefore includes multiple rank-local
NetCDF files in addition to the global covariance products.

## Generated data volume

Approximate working-directory sizes at the time of publication:

- NICAS: 192 GB
- VBAL: 81 GB
- HDIAGS: 29 GB
- BUMPLOC: 8.7 GB

These sizes include working, intermediate and distributed products
and should not be interpreted as the size of a single covariance file.

## Availability

The complete generated NetCDF covariance dataset is not stored in
GitHub because of its size.

This repository contains the scripts and configuration required to
reproduce the workflow.

## Site-specific configuration

The scripts are published substantially as used on the original
HPE Cray environment. Paths under `/scratch/lus/...`, Slurm resource
settings, module names and filesystem locations must be adapted for
other systems.
