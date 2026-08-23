NMC Sample Generation for MPAS-JEDI SABER/BUMP

This directory contains the workflow used to generate NMC-method forecast-difference samples for training MPAS-JEDI background-error covariance models with SABER/BUMP.

The purpose of this preprocessing stage is to start from native MPAS forecast states and produce a consistent population of perturbation files:

PTB_f48mf24_001.nc
PTB_f48mf24_002.nc
...
PTB_f48mf24_NNN.nc

These samples are then used by the downstream B-matrix calibration stages:

Native MPAS forecasts
        |
        v
NMC sample preparation
        |
        v
PTB_f48mf24_*.nc
        |
        v
VBAL / HDIAGS / NICAS
        |
        v
SABER-BUMP background-error covariance

The NMC sample-preparation procedure is kept outside the MPAS-JEDI version-specific directories because the methodology itself is independent of whether the downstream calibration is performed with MPAS-JEDI 3.x, 4.x, or another compatible release.

Directory contents

bmatrix/nmc/
├── README.md
└── scripts/
    ├── prepare_nmc_samples.sh
    ├── collect_samples.sh
    └── common_runtime.sh

scripts/prepare_nmc_samples.sh

Main NMC preprocessing driver. It:

scans the native MPAS forecast archive;

determines initialization and valid times;

calculates actual forecast lead times;

selects the configured short- and long-lead forecasts;

creates technical F24/F48 links and inventories;

creates the NetCDF template used by the conversion stage;

converts MPAS horizontal wind to stream function and velocity potential;

constructs temperature and specific humidity;

adds surface pressure, reconstructed winds, relative humidity, and available hydrometeors;

builds complete short- and long-lead forecast states;

forms the NMC difference;

collects the valid perturbation samples.

The expensive conversion, augmentation, and differencing stages are executed through Slurm arrays.

scripts/collect_samples.sh

Collects already generated perturbations and creates sequential symbolic links:

PTB_f48mf24_001.nc
PTB_f48mf24_002.nc
...

No large NetCDF files are duplicated.

scripts/common_runtime.sh

Provides the MPAS-JEDI runtime/resource definitions needed during preprocessing. Site-specific installation paths can be overridden through environment variables.

Scientific principle

The NMC method uses differences between forecasts having different forecast lengths but corresponding to the same verification time.

For a configured short-lead forecast state x_short and long-lead forecast state x_long,

delta_x_NMC = x_long - x_short

A collection of these forecast differences is used as the statistical sample population from which SABER/BUMP estimates background-error structures.

Actual forecast leads and technical F24/F48 labels

The historical workflow uses the filenames:

FULL_f24.nc
FULL_f48.nc
PTB_f48mf24.nc

However, F24 and F48 are retained as technical workflow labels. The actual physical forecast leads are configured independently.

The development dataset used:

NMC_SHORT_LEAD=12
NMC_LONG_LEAD=24

with the mapping:

actual +12 h forecast  -> technical F24
actual +24 h forecast  -> technical F48

Therefore:

FULL_f24.nc = configured short-lead state
FULL_f48.nc = configured long-lead state

and the perturbation is always:

PTB_f48mf24.nc = FULL_f48.nc - FULL_f24.nc

For a conventional +24 h / +48 h experiment, use:

export NMC_SHORT_LEAD=24
export NMC_LONG_LEAD=48

No source-code modification is required.

Native MPAS input

The preprocessing operates on native MPAS forecast files.

The default source archive used during development is:

/scratch/lus/tmp/arw/day/nmc

The source can be changed with:

export SRC_NMC=/path/to/native/mpas/nmc

The expected archive structure is:

SRC_NMC/
├── YYYYMMDDHH/
│   ├── MPAS.YYYY-MM-DD_HH.nc
│   └── ...
├── YYYYMMDDHH/
│   └── ...
└── ...

The parent directory identifies the forecast initialization cycle. The valid time is read from the MPAS filename.

For each file,

forecast lead = valid time - initialization time

is calculated.

Only forecasts matching NMC_SHORT_LEAD or NMC_LONG_LEAD are retained.

Same-verification-time pairing

The short- and long-lead forecasts used in one NMC perturbation must correspond to the same verification time.

cycle A ---- short lead ----> valid time V
cycle B ----- long lead ----> valid time V
                                 |
                                 v
                         long - short

Only complete forecast pairs are allowed to enter the NMC sample population.

Cycle filtering

The source period can be restricted using:

export START_CYCLE=YYYYMMDDHH
export END_CYCLE=YYYYMMDDHH

If they are not specified, the complete available archive is considered.

NMC working directory

Generated NetCDF products should be kept outside the Git repository because they are large.

The default working root is:

$HOME/jedi/nmc_samples

It can be overridden with:

export NMC_ROOT=/path/to/nmc_samples

The generated tree contains approximately:

NMC_ROOT/
├── input/
│   └── native_mpas_INIT_links/
├── lists/
├── logs/
├── output/
├── samples/
├── templates/
└── work_addvar/

Forecast inventories and INIT links

Selected native MPAS files are exposed through links named:

INIT.YYYY-MM-DD_HH.F24.nc
INIT.YYYY-MM-DD_HH.F48.nc

The script also creates inventories including:

lists/inventory.txt
lists/f24_files.txt
lists/f48_files.txt

The inventory records the initialization cycle, actual forecast lead, technical F24/F48 label, valid time, source file, and generated link.

Geometry requirements

Both forecasts forming a perturbation must use compatible MPAS geometry:

same horizontal mesh;

same number of cells;

same number of vertical levels;

same vertical-coordinate definition;

compatible variable dimensions and staggering.

No implicit interpolation between different MPAS meshes should be introduced during the final NMC differencing stage.

Template construction

The workflow creates:

templates/template_PTB.nc

A native MPAS theta field is used only to establish the required dimensions.

Zero-valued structural placeholders are created for:

stream_function
velocity_potential
temperature
spechum

These placeholders are not the final physical fields. They are replaced later by the converted/calculated values.

The template also carries native fields required by the workflow:

uReconstructZonal
uReconstructMeridional
relhum
surface_pressure

and, when present:

qc
qi
qr
qs
qg

Wind transformation

The MPAS horizontal wind is transformed into the control variables:

stream_function
velocity_potential

using the conversion utility:

fast_3_convert_one.py

and the configured conversion/remapping resources:

TOOLS_DIR
WEIGHTS_DIR
LATLON_PREFIX

The conversion produces the initial complete-state files:

FULL_f24.nc
FULL_f48.nc

which are then augmented with the final thermodynamic and native MPAS fields.

Temperature construction

Physical temperature is calculated from MPAS potential temperature and pressure:

T = theta * (p / 100000)^(2/7)

If the native MPAS file contains pressure, it is used directly.

Otherwise:

pressure = pressure_base + pressure_p

is used.

The resulting field is stored as temperature with units of K.

The temporary temperature variable created during template construction is therefore only a structural placeholder and is overwritten by the physically calculated field.

Specific humidity construction

Native MPAS qv is converted to specific humidity using:

spechum = qv / (1 + qv)

The resulting field is stored as spechum with units kg kg-1.

Additional native MPAS variables

The complete forecast states also retain:

surface_pressure
uReconstructZonal
uReconstructMeridional
relhum

When present in the native forecasts, the following hydrometeors are also retained:

qc
qi
qr
qs
qg

The downstream B-matrix configuration must remain consistent with the variables available in the NMC samples.

Complete forecast states

For each valid verification time, preprocessing produces:

output/YYYYMMDDHH/FULL_f24.nc
output/YYYYMMDDHH/FULL_f48.nc

The workflow verifies the presence of the principal control variables:

stream_function
velocity_potential
temperature
spechum
surface_pressure

Only directories containing both complete states are retained for NMC differencing.

NMC difference

For every complete pair:

PTB_f48mf24 = FULL_f48 - FULL_f24

The implementation uses NCO:

ncdiff -O FULL_f48.nc FULL_f24.nc PTB_f48mf24.nc

The resulting file is written as:

output/YYYYMMDDHH/PTB_f48mf24.nc

The perturbation is checked for the principal control variables before it is accepted.

Sample collection

Valid perturbations are collected under:

samples/

through sequential symbolic links:

PTB_f48mf24_001.nc
PTB_f48mf24_002.nc
PTB_f48mf24_003.nc
...

collect_samples.sh accepts a sample only when the source directory contains:

FULL_f24.nc
FULL_f48.nc
PTB_f48mf24.nc

Symbolic links avoid unnecessary duplication of large MPAS NetCDF files.

Connection to B-matrix calibration

The resulting samples are used directly by the downstream SABER/BUMP training workflow:

PTB_f48mf24_*.nc
        |
        +--> VBAL
        |
        +--> HDIAGS
        |
        +--> NICAS
        |
        v
SABER/BUMP covariance products

The release- and grid-specific calibration scripts remain under directories such as:

bmatrix/3.0.3/
bmatrix/4.0.0/

while the NMC preparation is shared.

Software requirements

The preprocessing requires:

Bash;

Slurm;

Python 3;

numpy;

netCDF4;

NCO.

The NCO commands used include:

ncks
ncrename
ncatted
ncdiff

The wind/control-variable conversion also requires the corresponding transformation utility and weights.

Runtime environment

A site-specific initialization script can be supplied with:

export NMC_ENV_SCRIPT=/path/to/environment/setup.sh

If the script does not exist, the workflow assumes that the required software environment is already loaded.

The MPAS-JEDI/runtime paths used by common_runtime.sh can be overridden through variables such as:

MPAS_JEDI_INSTALL
MPAS_JEDI_CODE
MPAS_BUILD
MPAS_JEDI_NAMELISTS
MPAS_PHYSICS_DIR

Slurm configuration

The main driver uses Slurm arrays for the expensive preprocessing stages.

The principal configurable resources are:

ARRAY_PARTITION
CONVERT_CPUS
ADDVAR_CPUS
NCDIFF_CPUS
CONVERT_THROTTLE
ADDVAR_THROTTLE
NCDIFF_THROTTLE

Intermediate files use the Slurm TMPDIR when available, while final NetCDF products are written to NMC_ROOT/output.

Typical configuration

For the historical experiment:

export NMC_ROOT=$HOME/jedi/nmc_samples
export SRC_NMC=/scratch/lus/tmp/arw/day/nmc
export NMC_SHORT_LEAD=12
export NMC_LONG_LEAD=24
export NMC_ENV_SCRIPT=/path/to/software/environment.sh

Then run:

./bmatrix/nmc/scripts/prepare_nmc_samples.sh

To rebuild only the numbered sample links from already generated perturbations:

./bmatrix/nmc/scripts/collect_samples.sh "$NMC_ROOT"

For true +24 h / +48 h forecasts:

export NMC_SHORT_LEAD=24
export NMC_LONG_LEAD=48

The historical output filenames remain unchanged for compatibility, while the inventory records the actual forecast leads used.

Quality control

Before using the samples for SABER/BUMP training, verify:

identical MPAS geometry across all samples;

identical vertical structure;

consistent short- and long-lead definitions;

same verification time within every forecast pair;

presence of all required control variables;

absence of NaN/Inf/fill-value contamination;

physically reasonable perturbation amplitudes;

adequate sample population;

hydrometeor consistency when those variables are included in B;

absence of unintended remapping during the final differencing stage.

Reproducibility information

A reproducible B-matrix experiment should record at least:

MPAS mesh
horizontal resolution
number of cells
number of vertical levels
training period
cycle frequency
NMC_SHORT_LEAD
NMC_LONG_LEAD
number of accepted samples
sample variables
hydrometeor variables
conversion-tool version
transformation/remapping weights
MPAS-JEDI/SABER version used downstream
VBAL configuration
HDIAGS configuration
NICAS configuration

Summary

The complete NMC preparation chain is:

Native MPAS forecasts
        |
        v
Determine forecast leads
        |
        v
Select short/long forecast pair
        |
        v
U/V -> stream_function + velocity_potential
        |
        v
theta + pressure -> temperature
qv -> spechum
        |
        v
retain surface pressure, winds, RH, hydrometeors
        |
        v
FULL_f24.nc
FULL_f48.nc
        |
        v
FULL_f48 - FULL_f24
        |
        v
PTB_f48mf24.nc
        |
        v
PTB_f48mf24_001.nc ... PTB_f48mf24_NNN.nc
        |
        v
VBAL / HDIAGS / NICAS
        |
        v
SABER/BUMP background-error covariance

This provides the missing reproducible path from native MPAS forecasts to the perturbation population used for MPAS-JEDI background-error covariance training.
