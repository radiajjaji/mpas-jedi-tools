#!/bin/bash
#SBATCH --job-name=hdiags_2_400intel
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --output=logs/hdiags_2.out
#SBATCH --error=logs/hdiags_2.err

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

SAMPLES_DIR="${HOPT_SAMPLES_DIR:-${ROOT}/samples}"
HDIAG_DIR="${ROOT}/HDIAGS"
WORKDIR="${HDIAG_DIR}/vargroup2"
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
require_file "${INVARIANT}"
require_file "${TEMPLATE}"

NMEMBERS=$(find "${SAMPLES_DIR}" -maxdepth 1 -name 'PTB_f48mf24_*.nc' | wc -l)
[ "${NMEMBERS}" -gt 1 ] || fatal "not enough hydro samples in ${SAMPLES_DIR}: ${NMEMBERS}"


BG_FILE=$(find "${ROOT}/background" -type f -name 'INIT.*.F48.nc' | sort | head -1)
require_file "${BG_FILE}"

base=$(basename "${BG_FILE}")
REF_DATE_TIME=$(echo "$base" | sed -n 's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p')
[ -n "${REF_DATE_TIME}" ] || fatal "cannot parse REF_DATE_TIME from ${base}"

DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

ln -sfn ${GRAPH_PREFIX}* .
ln -sfn "${INVARIANT}" "x1.${GRID}.invariant.nc"
ln -sfn "${BG_FILE}" "bg.${REF_DATE_TIME}.00.00.nc"
ln -sfn "${BG_FILE}" "templateFields.${GRID}.nc"
ln -sfn "${BG_FILE}" background.nc

require_file "${PWD}/bg.${REF_DATE_TIME}.00.00.nc"
require_file "${PWD}/templateFields.${GRID}.nc"
require_file "${PWD}/background.nc"

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
    config_physics_suite = 'mesoscale_reference'
/
&assimilation
    config_jedi_da = true
/
EOF_NML

cat > run_hdiag_hydro.yaml <<EOF_YAML
_member config: &memberConfig
  state variables: &vars
  - cloud_liquid_water
  - cloud_liquid_ice
  - rain_water
  - snow_water
  - graupel
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
        filename: ${SAMPLES_DIR}/PTB_f48mf24_%iMember%.nc
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
        computation grid size: 24000
        diagnostic grid size: 1000
        distance classes: 20
        distance class width: 200.0e3
        reduced levels: 10
        local diagnostic: true
        averaging length-scale: 3000.0e3
      variance:
        objective filtering: true
        filtering iterations: 1
        initial length-scale:
        - variables: *vars
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

log "Running HDIAGS vargroup2 hydrometeors with ${NMEMBERS} samples from ${SAMPLES_DIR}"
srun -n "${SLURM_NTASKS}" --cpu-bind=cores "${JEDI_EXE}" ./run_hdiag_hydro.yaml ./run_hdiag_hydro.runlog

require_file "${WORKDIR}/mpas.stddev.nc"
require_file "${WORKDIR}/mpas.cor_rh.nc"
require_file "${WORKDIR}/mpas.cor_rv.nc"

log "DONE HDIAGS vargroup2: ${WORKDIR}"
