#!/bin/bash
#SBATCH --job-name=hdiags_1_intel400
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --output=logs/hdiags_1.out
#SBATCH --error=logs/hdiags_1.err

set -x

VERSION="${VERSION:-4.0.0}"
ROOT="${ROOT:-${HOME}/jedi/mpas_only/${VERSION}}"
GRID="${GRID:-4096002}"
NLEVELS="${NLEVELS:-56}"
JEDI_INSTALL="${JEDI_INSTALL:-${HOME}/intel400/mpas-install}"
JEDI_EXE="${JEDI_INSTALL}/bin/mpasjedi_error_covariance_toolbox.x"
MPAS_MESH_DIR="${MPAS_MESH_DIR:-/scratch/lus/arw/model/src/mpas/meshes/12}"
INVARIANT="${MPAS_MESH_DIR}/x1.${GRID}.invariant.nc"
GRAPH_PREFIX="${MPAS_MESH_DIR}/x1.${GRID}.graph.info.part."

SAMPLES_UNBALANCED_DIR="${ROOT}/samplesUnbalanced"
HDIAG_DIR="${ROOT}/HDIAGS"
WORKDIR="${HDIAG_DIR}/vargroup1"
VBAL_DIR="${ROOT}/VBAL"
INPUT_DIR="${ROOT}/input/native_mpas_INIT_links"
TEMPLATE="${ROOT}/templates/template_PTB.nc"
LOG_DIR="${ROOT}/logs"

log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fatal(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2; exit 1; }
require_file(){ [ -s "$1" ] || fatal "missing required file: $1"; }

# INTEL Spack-stack 1.9.3 runtime.
source /scratch/lus/arw/spack-stack-1.9.3-intel/switch_to_intel.sh
source "${ROOT}/common_runtime.sh"

mkdir -p "${LOG_DIR}"

[ -x "${JEDI_EXE}" ] || fatal "missing executable ${JEDI_EXE}"
require_file "${VBAL_DIR}/mpas_vbal.nc"
require_file "${VBAL_DIR}/mpas_sampling.nc"
require_file "${INVARIANT}"
require_file "${TEMPLATE}"

NMEMBERS=$(find "${SAMPLES_UNBALANCED_DIR}" -maxdepth 1 -name 'PTB_f48mf24_*.nc' | wc -l)
[ "${NMEMBERS}" -gt 1 ] || fatal "not enough unbalanced samples: ${NMEMBERS}"


BG_FILE="/scratch/lus/arw/jedi/Bflow_preprocessing/output/2026051300/FULL_f48.nc"
require_file "${BG_FILE}"

TEMPLATE_FIELDS=$(find "${INPUT_DIR}" \( -type f -o -type l \) -name 'INIT.*.F48.nc' | sort | head -1)
require_file "${TEMPLATE_FIELDS}"

base=$(basename "${TEMPLATE_FIELDS}")
REF_DATE_TIME=$(echo "$base" | sed -n 's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p')
[ -n "${REF_DATE_TIME}" ] || fatal "cannot parse REF_DATE_TIME from ${base}"

DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

ln -sfn ${GRAPH_PREFIX}* .
ln -sfn "${INVARIANT}" "x1.${GRID}.invariant.nc"
ln -sfn "${BG_FILE}" "bg.${REF_DATE_TIME}.00.00.nc"
ln -sfn "${TEMPLATE_FIELDS}" "templateFields.${GRID}.nc"

ln -sfn "${TEMPLATE}" output.nc
ln -sfn "${TEMPLATE}" control.nc
ln -sfn "${TEMPLATE}" ensemble.nc
stage_resources "${PWD}" || fatal "failed to stage MPAS-JEDI runtime resources"
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

cat > run_hdiags.yaml <<EOF_YAML
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
  nml_file: "./namelist.atmosphere"
  streams_file: "./streams.atmosphere"
  bump vunit: "avgheight"
background:
  state variables: *vars
  filename: "./bg.${REF_DATE_TIME}.00.00.nc"
  date: *date
  stream name: control
  transform model to analysis: false

background error:
  covariance model: SABER

  iterative ensemble loading: true

  ensemble:
    members from template:
      template:
        <<: *memberConfig
        filename: ${SAMPLES_UNBALANCED_DIR}/PTB_f48mf24_%iMember%.nc
      pattern: %iMember%
      start: 1
      zero padding: 3
      nmembers: ${NMEMBERS}

  saber central block:
    saber block name: BUMP_NICAS
    calibration:
      io:
        files prefix: mpas
      drivers:
        compute covariance: true
        compute correlation: true
        multivariate strategy: univariate
        write global sampling: true
        compute variance: true
        compute moments: true
        write diagnostics: true
      sampling:
        computation grid size: 12000
        diagnostic grid size: 1000
        distance classes: 10
        distance class width: 1000.0e3
        reduced levels: 10
        local diagnostic: true
        averaging length-scale: 3000.0e3
      variance:
        objective filtering: true
        filtering iterations: 1
        initial length-scale:
        - variables:
          - stream_function
          - velocity_potential
          - temperature
          - spechum
          - surface_pressure
          value: 3000.0e3
      fit:
        horizontal filtering length-scale: 3000.0e3

      output model files:
      - parameter: stddev
        file:
          filename: ./mpas.stddev.nc
          date: *date
          stream name: control
      - parameter: cor_rh
        file:
          filename: ./mpas.cor_rh.nc
          date: *date
          stream name: control
      - parameter: cor_rv
        file:
          filename: ./mpas.cor_rv.nc
          date: *date
          stream name: control
EOF_YAML

log "Running HDIAGS vargroup1 with ${NMEMBERS} unbalanced samples from ${SAMPLES_UNBALANCED_DIR}"
srun -n "${SLURM_NTASKS}" --cpu-bind=cores "${JEDI_EXE}" ./run_hdiags.yaml ./run_hdiags.runlog

require_file "${WORKDIR}/mpas.stddev.nc"
require_file "${WORKDIR}/mpas.cor_rh.nc"
require_file "${WORKDIR}/mpas.cor_rv.nc"

log "DONE HDIAGS vargroup1: ${WORKDIR}"
