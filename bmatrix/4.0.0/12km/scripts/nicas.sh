#!/bin/bash
#SBATCH --job-name=nicas_400intel
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=06:00:00
#SBATCH --output=logs/nicas.%x.%j.out
#SBATCH --error=logs/nicas.%x.%j.out

set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# MPAS-JEDI 4.0.0 NICAS generation using MPAS-JEDI 4.0.0 HDIAGS
# -----------------------------------------------------------------------------

OUTPUT_VERSION="${OUTPUT_VERSION:-4.0.0}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${HOME}/jedi/mpas_only/${OUTPUT_VERSION}}"

GRID="${GRID:-4096002}"

# MPAS-JEDI 4.0.0 Intel installation.
JEDI_INSTALL="${JEDI_INSTALL:-${HOME}/intel400/mpas-install}"
JEDI_EXE="${JEDI_INSTALL}/bin/mpasjedi_error_covariance_toolbox.x"

# MPAS mesh and decomposition files.
MPAS_MESH_DIR="${MPAS_MESH_DIR:-/scratch/lus/arw/model/src/mpas/meshes/12}"
INVARIANT="${MPAS_MESH_DIR}/x1.${GRID}.invariant.nc"
GRAPH_PREFIX="${MPAS_MESH_DIR}/x1.${GRID}.graph.info.part."

# ${SLURM_NTASKS} is available when the script runs under sbatch.
GRAPH_FILE="${GRAPH_PREFIX}${SLURM_NTASKS}"

# HDIAGS and NICAS trees are both under MPAS-JEDI 4.0.0.
HDIAG_DIR="${HDIAG_DIR:-${OUTPUT_ROOT}/HDIAGS}"
NICAS_DIR="${NICAS_DIR:-${OUTPUT_ROOT}/NICAS}"
LOG_DIR="${LOG_DIR:-${OUTPUT_ROOT}/logs}"

# TEMPLATE_FIELDS is resolved after BG_FILE and REF_DATE_TIME are known.
# By default, use the same native MPAS state as the background so that the
# input-stream timestamp exactly matches the geometry/background timestamp.
TEMPLATE_FIELDS="${TEMPLATE_FIELDS:-}"

# Run one JEDI variable per submitted job.
NICAS_VAR="${NICAS_VAR:-stream_function}"

ALL_VARS="\
stream_function \
velocity_potential \
temperature \
spechum \
surface_pressure \
qc \
qi \
qr \
qs \
qg"

log()
{
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

fatal()
{
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2
    exit 1
}

require_file()
{
    [ -s "$1" ] || fatal "missing or empty required file: $1"
}

require_dir()
{
    [ -d "$1" ] || fatal "missing required directory: $1"
}

case " ${ALL_VARS} " in
    *" ${NICAS_VAR} "*)
        ;;
    *)
        fatal "unsupported NICAS_VAR=${NICAS_VAR}"
        ;;
esac

# NICAS_VAR uses the native MPAS/HDIAGS variable name.
# Translate only the variable name passed to JEDI/SABER.
MPAS_VAR="${NICAS_VAR}"

case "${NICAS_VAR}" in
    qc)
        JEDI_VAR="cloud_liquid_water"
        ;;
    qi)
        JEDI_VAR="cloud_liquid_ice"
        ;;
    qr)
        JEDI_VAR="rain_water"
        ;;
    qs)
        JEDI_VAR="snow_water"
        ;;
    qg)
        JEDI_VAR="graupel"
        ;;
    *)
        JEDI_VAR="${NICAS_VAR}"
        ;;
esac

# Native name is used for directories and HDIAGS identification.
variable_dir="${MPAS_VAR}"

# JEDI name is passed to the YAML configuration.
variable="${JEDI_VAR}"

# Variable-dependent maximum NICAS horizontal sampling grid size.
# NCAR uses a larger limit for hydrometeors because their diagnosed
# horizontal correlation supports are often much broader and more irregular.
nc1max=15000
resolution=8
hydrometeor_nicas_yaml=""

case "${NICAS_VAR}" in
    qc|qi|qr|qs|qg)
        nc1max=60000
        resolution=4

        # Hydrometeor-only explicit horizontal Gaspari-Cohn support radius.
        # The JEDI variable name is used because this block is interpreted
        # by SABER/BUMP after the native MPAS-to-JEDI name translation.
        hydrometeor_nicas_yaml="$(cat <<EOF_HYDRO_NICAS
        explicit length-scales: true
        horizontal length-scale:
        - groups:
          - ${JEDI_VAR}
          value: 300.0e3
EOF_HYDRO_NICAS
)"
        ;;
esac

# -----------------------------------------------------------------------------
# Intel runtime
# -----------------------------------------------------------------------------

# The environment loader may return a harmless nonzero status when the
# spack-stack repository is already registered. Do not let `set -e` terminate
# the NICAS job during that initialization.
set +x
set +e

source /scratch/lus/arw/spack-stack-1.9.3-intel/switch_to_intel.sh
intel_env_rc=$?

set -e
set -x

if [ "${intel_env_rc}" -ne 0 ]; then
    log "WARNING: switch_to_intel.sh returned rc=${intel_env_rc}; validating the loaded runtime"
fi

# Use libraries from the same installation as the executable.
export LD_LIBRARY_PATH="${JEDI_INSTALL}/lib:${JEDI_INSTALL}/lib64:${LD_LIBRARY_PATH:-}"

# Eight cores are reserved per rank for memory placement; BUMP runs one
# OpenMP thread per MPI rank unless explicitly changed.
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export OOPS_NUM_THREADS="${OOPS_NUM_THREADS:-1}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-1}"

export HDF5_USE_FILE_LOCKING=FALSE

require_file "${JEDI_EXE}"

if ldd "${JEDI_EXE}" | grep -q 'not found'; then
    ldd "${JEDI_EXE}" | grep 'not found' >&2
    fatal "unresolved shared libraries for ${JEDI_EXE}"
fi

# -----------------------------------------------------------------------------
# Runtime helper and required resources
# -----------------------------------------------------------------------------

require_file "${OUTPUT_ROOT}/common_runtime.sh"
source "${OUTPUT_ROOT}/common_runtime.sh"

mkdir -p "${LOG_DIR}"
mkdir -p "${NICAS_DIR}"

require_file "${HDIAG_DIR}/merge/mpas.cor_rh.nc"
require_file "${HDIAG_DIR}/merge/mpas.cor_rv.nc"
require_file "${HDIAG_DIR}/merge/mpas.stddev.nc"

require_file "${INVARIANT}"
require_file "${GRAPH_FILE}"
require_dir "${OUTPUT_ROOT}/background"

# -----------------------------------------------------------------------------
# Select the background file
#
# BG_FILE and REF_DATE_TIME may be supplied explicitly:
#
#   BG_FILE=/path/INIT.2026-05-13_00.F48.nc
#   REF_DATE_TIME=2026-05-13_00
# -----------------------------------------------------------------------------

BG_FILE="${BG_FILE:-}"

if [ -z "${BG_FILE}" ]; then
    BG_FILE=$(
        find "${OUTPUT_ROOT}/background" \
            -maxdepth 1 \
            -type f \
            -name 'INIT.*.F48.nc' \
            | sort \
            | head -1
    )
fi

require_file "${BG_FILE}"

REF_DATE_TIME="${REF_DATE_TIME:-}"

if [ -z "${REF_DATE_TIME}" ]; then
    base=$(basename "${BG_FILE}")

    # Expected form:
    # INIT.2026-05-13_00.F48.nc
    REF_DATE_TIME=$(
        printf '%s\n' "${base}" |
        sed -n \
          's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p'
    )

    # Also accept:
    # MPAS.2026-05-13_00.nc
    if [ -z "${REF_DATE_TIME}" ]; then
        REF_DATE_TIME=$(
            printf '%s\n' "${base}" |
            sed -n \
              's/^MPAS\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.nc$/\1/p'
        )
    fi
fi

[ -n "${REF_DATE_TIME}" ] ||
    fatal "cannot determine REF_DATE_TIME from BG_FILE=${BG_FILE}; export REF_DATE_TIME=YYYY-MM-DD_HH"

DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

# The MPAS input stream requires templateFields to contain REF_DATE_TIME.
# Use BG_FILE by default because its timestamp was used to derive
# REF_DATE_TIME. A separately supplied TEMPLATE_FIELDS must contain the
# identical timestamp.
if [ -z "${TEMPLATE_FIELDS}" ]; then
    TEMPLATE_FIELDS="${BG_FILE}"
fi

require_file "${TEMPLATE_FIELDS}"

log "OUTPUT_VERSION       = ${OUTPUT_VERSION}"
log "OUTPUT_ROOT          = ${OUTPUT_ROOT}"
log "JEDI_INSTALL         = ${JEDI_INSTALL}"
log "JEDI_EXE             = ${JEDI_EXE}"
log "HDIAGS directory     = ${HDIAG_DIR}/merge"
log "NICAS directory      = ${NICAS_DIR}/${variable_dir}"
log "TEMPLATE_FIELDS      = ${TEMPLATE_FIELDS}"
log "BG_FILE              = ${BG_FILE}"
log "REF_DATE_TIME        = ${REF_DATE_TIME}"
log "DATE_STRING          = ${DATE_STRING}"
log "NICAS_VAR submitted  = ${NICAS_VAR}"
log "MPAS/HDIAGS variable = ${MPAS_VAR}"
log "JEDI/SABER variable  = ${JEDI_VAR}"
log "NICAS resolution     = ${resolution}"
log "NICAS nc1max         = ${nc1max}"

if [ -n "${hydrometeor_nicas_yaml}" ]; then
    log "NICAS horizontal RH  = explicit 300 km for ${JEDI_VAR}"
else
    log "NICAS horizontal RH  = diagnosed from HDIAGS"
fi

log "MPI tasks            = ${SLURM_NTASKS}"
log "Graph file           = ${GRAPH_FILE}"

# -----------------------------------------------------------------------------
# Prepare variable-specific NICAS directory
# -----------------------------------------------------------------------------

rm -rf "${NICAS_DIR:?}/${variable_dir}"
mkdir -p "${NICAS_DIR}/${variable_dir}"
cd "${NICAS_DIR}/${variable_dir}"

rm -f \
    mpas_nicas.nc \
    mpas_nicas_local_*.nc \
    mpas_nicas_grids_local_*.nc \
    mpas.nicas_norm.nc \
    mpas.dirac_nicas.nc \
    run_nicas.runlog

# MPAS resources.
ln -sfn "${GRAPH_FILE}" .
ln -sfn "${INVARIANT}" "x1.${GRID}.invariant.nc"

# State/template files.
ln -sfn "${BG_FILE}" "bg.${REF_DATE_TIME}.00.00.nc"
ln -sfn "${BG_FILE}" background.nc

ln -sfn "${TEMPLATE_FIELDS}" "templateFields.${GRID}.nc"
ln -sfn "${TEMPLATE_FIELDS}" output.nc
ln -sfn "${TEMPLATE_FIELDS}" control.nc
ln -sfn "${TEMPLATE_FIELDS}" ensemble.nc

stage_resources "${PWD}" ||
    fatal "failed to stage MPAS-JEDI 4.0.0 runtime resources"

write_streams "${PWD}" "${GRID}" ||
    fatal "failed to write streams.atmosphere"

# Native MPAS fields that may be used by the control stream.
cat > stream_list.atmosphere.control <<'EOF_CONTROL'
spechum
stream_function
surface_pressure
temperature
velocity_potential
uReconstructMeridional
uReconstructZonal
scalars
EOF_CONTROL

# Merged MPAS-JEDI 4.0.0 HDIAGS products.
ln -sfn "${HDIAG_DIR}/merge/mpas.cor_rh.nc" mpas.cor_rh.nc
ln -sfn "${HDIAG_DIR}/merge/mpas.cor_rv.nc" mpas.cor_rv.nc
ln -sfn "${HDIAG_DIR}/merge/mpas.stddev.nc" mpas.stddev.nc

if [ "${variable}" = "surface_pressure" ]; then
    vert_level_dirac=1
else
    vert_level_dirac=36
fi

# -----------------------------------------------------------------------------
# MPAS namelist
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# NICAS calibration configuration
# -----------------------------------------------------------------------------

cat > run_nicas.yaml <<EOF_YAML
geometry:
  nml_file: ./namelist.atmosphere
  streams_file: ./streams.atmosphere
  bump vunit: avgheight

background:
  state variables:
  - ${variable}
  filename: ./bg.${REF_DATE_TIME}.00.00.nc
  date: '${DATE_STRING}'
  stream name: control
  transform model to analysis: false

background error:
  covariance model: SABER

  saber central block:
    saber block name: BUMP_NICAS

    active variables:
    - ${variable}

    calibration:
      io:
        data directory: .
        files prefix: mpas

      drivers:
        multivariate strategy: univariate
        compute nicas: true
        write local nicas: true
        write global nicas: true
        write nicas grids: true
        internal dirac test: true

      sampling:
        computation grid size: 100000
        diagnostic grid size: 1000
        reduced levels: 56
        averaging latitude width: 10.0

      nicas:
        resolution: ${resolution}
        max horizontal grid size: ${nc1max}
${hydrometeor_nicas_yaml}

      dirac:
      - longitude: -45.0
        latitude: 0.0
        level: ${vert_level_dirac}
        variable: ${variable}

      - longitude: -135.0
        latitude: 0.0
        level: ${vert_level_dirac}
        variable: ${variable}

      - longitude: 45.0
        latitude: 0.0
        level: ${vert_level_dirac}
        variable: ${variable}

      - longitude: 135.0
        latitude: 0.0
        level: ${vert_level_dirac}
        variable: ${variable}

      input model files:
      - parameter: rh
        file:
          filename: ./mpas.cor_rh.nc
          date: '${DATE_STRING}'
          stream name: control

      - parameter: rv
        file:
          filename: ./mpas.cor_rv.nc
          date: '${DATE_STRING}'
          stream name: control

      output model files:
      - parameter: nicas_norm
        file:
          filename: ./mpas.nicas_norm.nc
          date: '${DATE_STRING}'
          stream name: control

      - parameter: dirac_nicas
        file:
          filename: ./mpas.dirac_nicas.nc
          date: '${DATE_STRING}'
          stream name: control
EOF_YAML

# -----------------------------------------------------------------------------
# Execute
# -----------------------------------------------------------------------------

set +e

srun \
    -n "${SLURM_NTASKS}" \
    --cpu-bind=cores \
    "${JEDI_EXE}" \
    ./run_nicas.yaml \
    ./run_nicas.runlog

rc=$?

set -e

if [ "${rc}" -ne 0 ]; then
    log "WARNING: srun returned rc=${rc}; validating generated products"
fi

# -----------------------------------------------------------------------------
# Validate products
# -----------------------------------------------------------------------------

require_file "mpas_nicas.nc"
require_file "mpas.nicas_norm.nc"
require_file "mpas.dirac_nicas.nc"

if ! compgen -G 'mpas_nicas_local_*.nc' >/dev/null; then
    fatal "missing mpas_nicas_local_*.nc for ${variable}"
fi

if ! compgen -G 'mpas_nicas_grids_local_*.nc' >/dev/null; then
    fatal "missing mpas_nicas_grids_local_*.nc for ${variable}"
fi

nlocal=$(
    find . \
        -maxdepth 1 \
        -type f \
        -name 'mpas_nicas_local_*.nc' |
    wc -l
)

ngrids=$(
    find . \
        -maxdepth 1 \
        -type f \
        -name 'mpas_nicas_grids_local_*.nc' |
    wc -l
)

if [ "${nlocal}" -ne "${SLURM_NTASKS}" ]; then
    fatal "expected ${SLURM_NTASKS} local NICAS files; found ${nlocal}"
fi

if [ "${ngrids}" -ne "${SLURM_NTASKS}" ]; then
    fatal "expected ${SLURM_NTASKS} local NICAS grid files; found ${ngrids}"
fi

log "NICAS valid for ${variable}"
log "Global NICAS file       : mpas_nicas.nc"
log "Normalization file      : mpas.nicas_norm.nc"
log "Dirac diagnostic file   : mpas.dirac_nicas.nc"
log "Local NICAS files       : ${nlocal}"
log "Local grid files        : ${ngrids}"
log "DONE Intel MPAS-JEDI NICAS ${OUTPUT_VERSION} for ${variable}"
