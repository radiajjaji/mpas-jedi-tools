# Native-MPAS B-Matrix — 24 km

## Status

Successfully generated from native MPAS forecast data.

## Data origin

The covariance-generation workflow starts from native
MPAS-Atmosphere states derived from the operational MPAS forecasting
system rather than forecast fields from another model converted into
MPAS representation.

## Resolution

- Horizontal resolution: approximately 24 km
- Covariance framework: SABER/BUMP

## Workflow

The published workflow contains:

- `vbal.sh` — vertical-balance calibration
- `hdiags_1.sh` — primary-variable HDIAGS calculation
- `hdiags_2.sh` — additional-variable/hydrometeor HDIAGS calculation
- `modify.hdiags.sh` — merge/tuning of HDIAGS products
- `nicas.sh` — NICAS generation
- `merge.nicas.sh` — merge of per-variable NICAS products
- `bumploc.sh` — BUMP/NICAS localization calibration

## Main covariance components

- VBAL
- HDIAGS
- NICAS
- BUMPLOC

## Generated data volume

The complete 24-km working tree was approximately 1.1 TB at the
time of publication.

This includes training, intermediate, diagnostic and distributed
NICAS products. The complete tree is therefore not suitable for
normal GitHub storage.

## Availability

Generation scripts and configuration are published here.

The complete generated covariance NetCDF dataset can be distributed
separately using an appropriate large scientific-data service.

## Site-specific configuration

The scripts are published substantially as used on the original
HPE Cray environment. Paths under `/scratch/lus/...`, Slurm resource
settings, module names and filesystem locations must be adapted for
other systems.
