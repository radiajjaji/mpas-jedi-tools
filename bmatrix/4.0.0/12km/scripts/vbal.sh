#!/bin/bash
#SBATCH --job-name=vbal_302intel
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --output=logs/vbal.%j.out
#SBATCH --error=logs/vbal.%j.err

set -x

VERSION="4.0.0"
ROOT="${ROOT:-${HOME}/jedi/mpas_only/${VERSION}}"
GRID="${GRID:-4096002}"
NLEVELS="${NLEVELS:-56}"
JEDI_INSTALL="${JEDI_INSTALL:-${HOME}/intel400/mpas-install}"
JEDI_EXE="${JEDI_INSTALL}/bin/mpasjedi_error_covariance_toolbox.x"
MPAS_MESH_DIR="${MPAS_MESH_DIR:-/scratch/lus/arw/model/src/mpas/meshes/12}"
INVARIANT="${MPAS_MESH_DIR}/x1.${GRID}.invariant.nc"
GRAPH_PREFIX="${MPAS_MESH_DIR}/x1.${GRID}.graph.info.part."

SAMPLES_DIR="${ROOT}/samples"
SAMPLES_UNBALANCED_DIR="${ROOT}/samplesUnbalanced"
VBAL_DIR="${ROOT}/VBAL"
TEMPLATE="${ROOT}/templates/template_PTB.nc"
OUTPUT_DIR="${ROOT}/output"
INPUT_DIR="${ROOT}/input/native_mpas_INIT_links"
LOG_DIR="${ROOT}/logs"

log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fatal(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2; exit 1; }
require_file(){ [ -s "$1" ] || fatal "missing required file: $1"; }
require_dir(){ [ -d "$1" ] || fatal "missing required directory: $1"; }

# Environment for MPAS-JEDI 3.0.2 executable.
# INTEL Spack-stack 1.9.3 runtime.
source /scratch/lus/arw/spack-stack-1.9.3-intel/switch_to_intel.sh
source "${ROOT}/common_runtime.sh"

mkdir -p "${LOG_DIR}" "${VBAL_DIR}" "${SAMPLES_UNBALANCED_DIR}"
cd "${ROOT}" || fatal "cannot cd ${ROOT}"

[ -x "${JEDI_EXE}" ] || fatal "missing executable ${JEDI_EXE}"
require_file "${INVARIANT}"
require_file "${TEMPLATE}"
require_dir "${SAMPLES_DIR}"

NMEMBERS=$(find "${SAMPLES_DIR}" -maxdepth 1 -name 'PTB_f48mf24_*.nc' | wc -l)

[ "${NMEMBERS}" -gt 1 ] ||     fatal "not enough samples in ${SAMPLES_DIR}: ${NMEMBERS}"

log "Using ${NMEMBERS} existing perturbation samples"

# Use a complete native MPAS INIT file as background/templateFields.
# Do NOT use output/FULL_f48.nc here: it lacks native MPAS dimensions such as nSoilLevels.
BG_FILE=$(find "${ROOT}/background" -type f -name 'INIT.*.F48.nc' | sort | head -1)
require_file "${BG_FILE}"

TEMPLATE_FIELDS="${BG_FILE}"
require_file "${TEMPLATE_FIELDS}"
base=$(basename "${TEMPLATE_FIELDS}")
REF_DATE_TIME=$(echo "$base" | sed -n 's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p')
[ -n "${REF_DATE_TIME}" ] || fatal "cannot parse REF_DATE_TIME from ${base}"
DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

rm -rf "${VBAL_DIR}" "${SAMPLES_UNBALANCED_DIR}"
mkdir -p "${VBAL_DIR}" "${SAMPLES_UNBALANCED_DIR}"
cd "${VBAL_DIR}" || fatal "cannot cd VBAL"

ln -sfn ${GRAPH_PREFIX}* .

# Mesh/static data for the invariant stream.
ln -sfn "${INVARIANT}" "x1.${GRID}.invariant.nc"

# Native MPAS state for the input and background streams.
ln -sfn "${BG_FILE}" "templateFields.${GRID}.nc"
ln -sfn "${BG_FILE}" "bg.${REF_DATE_TIME}.00.00.nc"
ln -sfn "${BG_FILE}" background.nc

# Templates used when writing control-space increments.
ln -sfn "${TEMPLATE}" output.nc
ln -sfn "${TEMPLATE}" control.nc
ln -sfn "${TEMPLATE}" ensemble.nc

stage_resources "${PWD}" || fatal "failed to stage runtime resources"
write_streams "${PWD}" "${GRID}" || fatal "failed to write streams.atmosphere"

cat > namelist.atmosphere <<EOF_NML
&nhyd_model
    config_time_integration_order = 2
    config_dt = 72.0
    config_start_time = '${REF_DATE_TIME}:00:00'
    config_run_duration = '0_06:00:00'
    config_split_dynamics_transport = true
    config_number_of_sub_steps = 2
    config_dynamics_split_steps = 3
    config_horiz_mixing = '2d_smagorinsky'
    config_len_disp = 12000.0
    config_scalar_advection = true
/
&io
    config_pio_num_iotasks = 0
    config_pio_stride = 1
/
&decomposition
    config_block_decomp_file_prefix = 'x1.${GRID}.graph.info.part.'
/
&restart
    config_do_restart = false
    config_do_DAcycling = true
/
&physics
    config_sst_update = false
    config_sstdiurn_update = false
    config_deepsoiltemp_update = false
    config_radtlw_interval = '00:30:00'
    config_radtsw_interval = '00:30:00'
    config_o3climatology = true
    config_bucket_update = 'none'
    config_physics_suite = 'mesoscale_reference'
    config_microp_re = true
/
&soundings
    config_sounding_interval = 'none'
/
&assimilation
    config_jedi_da = true
/
EOF_NML

cat > run_vbal.yaml <<EOF_YAML
_member config: &memberConfig
  state variables: &vars
  - stream_function
  - velocity_potential
  - temperature
  - spechum
  - surface_pressure
  date: &date '${DATE_STRING}'
  stream name: control
  transform model to analysis: false

geometry:
  nml_file: ./namelist.atmosphere
  streams_file: ./streams.atmosphere

background:
  state variables: *vars
  filename: ./bg.${REF_DATE_TIME}.00.00.nc
  date: *date
  stream name: background
  transform model to analysis: false

background error:
  covariance model: SABER
  iterative ensemble loading: false
  ensemble:
    members from template:
      template:
        <<: *memberConfig
        filename: ../samples/PTB_f48mf24_%mem%.nc
      pattern: '%mem%'
      nmembers: ${NMEMBERS}
      zero padding: 3
  output ensemble:
    filename: ../samplesUnbalanced/PTB_f48mf24_%{member}%.nc
    date: *date
    stream name: control
  saber central block:
    saber block name: ID
  saber outer blocks:
  - saber block name: BUMP_VerticalBalance
    calibration:
      io:
        files prefix: mpas
      drivers:
        write local sampling: true
        write global sampling: true
        compute vertical covariance: true
        compute vertical balance: true
        write vertical balance: true
        vertical balance inverse test: true
        adjoints test: true
      sampling:
        computation grid size: 100000
        diagnostic grid size: 1000
        reduced levels: ${NLEVELS}
        averaging latitude width: 10.0
      vertical balance:
        vbal:
        - balanced variable: velocity_potential
          unbalanced variable: stream_function
          diagonal regression: true
        - balanced variable: temperature
          unbalanced variable: stream_function
        - balanced variable: surface_pressure
          unbalanced variable: stream_function
        pseudo inverse: true
        dominant mode: 20
EOF_YAML

log "Running VBAL with ${NMEMBERS} samples"
srun -n "${SLURM_NTASKS}" --cpu-bind=cores "${JEDI_EXE}" ./run_vbal.yaml ./run_vbal.runlog

require_file "${VBAL_DIR}/mpas_vbal.nc"
require_file "${VBAL_DIR}/mpas_sampling.nc"
outn=$(find "${SAMPLES_UNBALANCED_DIR}" -maxdepth 1 -name 'PTB_f48mf24_*.nc' | wc -l)
[ "$outn" -eq "$NMEMBERS" ] || fatal "unbalanced sample count mismatch: $outn vs $NMEMBERS"
log "DONE VBAL"
