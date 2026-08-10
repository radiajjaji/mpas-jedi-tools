#!/bin/bash
#SBATCH --job-name=hdiags1_intel303_24km
#SBATCH --partition=dev
#SBATCH --nodelist=nid000[001-128]
#SBATCH --nodes=48
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=4
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs/hdiags_1.%j.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs/hdiags_1.%j.err

set -x

log()
{
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

fatal()
{
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2
    return 1
}

require_file()
{
    if [[ ! -s "$1" ]]; then
        fatal "missing required file: $1"
        return 1
    fi

    return 0
}

require_dir()
{
    if [[ ! -d "$1" ]]; then
        fatal "missing required directory: $1"
        return 1
    fi

    return 0
}

get_dimension()
{
    local FILE="$1"
    local DIMENSION="$2"

    ncdump -h "${FILE}" 2>/dev/null |
        sed -n \
            "s/^[[:space:]]*${DIMENSION} = \([0-9][0-9]*\) ;/\1/p" |
        head -1
}

get_xtime()
{
    local FILE="$1"
    local VALUE

    VALUE=$(
        ncdump -v xtime "${FILE}" 2>/dev/null |
        sed -n \
            's/.*"\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\).*/\1/p' |
        head -1
    )

    if [[ -n "${VALUE}" ]]; then
        printf '%s\n' "${VALUE}"
        return 0
    fi

    VALUE=$(
        ncdump -h "${FILE}" 2>/dev/null |
        sed -n \
            's/.*Time:units = "seconds since \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\) \([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\)".*/\1_\2/p' |
        head -1
    )

    if [[ -n "${VALUE}" ]]; then
        printf '%s\n' "${VALUE}"
        return 0
    fi

    VALUE=$(
        ncdump -h "${FILE}" 2>/dev/null |
        sed -n \
            's/.*:config_start_time = "\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\)".*/\1/p' |
        head -1
    )

    printf '%s\n' "${VALUE}"
}

main()
{
    local VERSION
    local PARENT_ROOT
    local ROOT
    local GRID
    local XNN
    local NLEVELS
    local MPAS_RESOLUTION

    local MODEL_ROOT
    local MODEL_ENV
    local OPER_ENV
    local MPASJEDI_INSTALL
    local JEDI_EXE
    local COMMON_RUNTIME

    local MPAS_MESH_DIR
    local INVARIANT
    local GRAPH_PREFIX
    local GRAPH_FILE

    local SAMPLES_UNBALANCED_DIR
    local HDIAG_DIR
    local HDIAGS_WORKDIR
    local VBAL_DIR
    local INPUT_DIR
    local LOG_DIR

    local BG_FILE
    local TEMPLATE_FIELDS
    local TEMPLATE
    local FIRST_SAMPLE

    local NMEMBERS
    local BASE
    local REF_DATE_TIME
    local DATE_STRING

    local SAMPLE_GRID
    local SAMPLE_LEVELS
    local BG_GRID
    local BG_LEVELS
    local BG_TIME

    local JEDI_RC
    local OUTPUT_GRID
    local OUTPUT_LEVELS

    #===========================================================================
    # Fixed workflow configuration
    #
    # Do not make workflow paths environment-overridable. These paths are used
    # by rm, ln, find and output operations.
    #===========================================================================

    VERSION="3.0.3"

    PARENT_ROOT="${HOME}/jedi/mpas_only/${VERSION}"
    ROOT="${PARENT_ROOT}/24km"

    GRID=1024002
    XNN="x1"
    NLEVELS=56
    MPAS_RESOLUTION=24

    MODEL_ROOT="/scratch/lus/arw/model"
    MODEL_ENV="${MODEL_ROOT}/slurm/modelenv.sh"
    OPER_ENV="${HOME}/spack-stack-oper/switch_to_oper.sh"

    MPASJEDI_INSTALL="${HOME}/intel303/mpas-install"
    JEDI_EXE="${MPASJEDI_INSTALL}/bin/mpasjedi_error_covariance_toolbox.x"

    COMMON_RUNTIME="${PARENT_ROOT}/common_runtime.sh"

    MPAS_MESH_DIR="${MODEL_ROOT}/src/mpas/meshes/${MPAS_RESOLUTION}"
    INVARIANT="${MPAS_MESH_DIR}/${XNN}.${GRID}.invariant.nc"
    GRAPH_PREFIX="${MPAS_MESH_DIR}/${XNN}.${GRID}.graph.info.part."
    GRAPH_FILE="${GRAPH_PREFIX}${SLURM_NTASKS}"

    SAMPLES_UNBALANCED_DIR="${ROOT}/samplesUnbalanced"
    HDIAG_DIR="${ROOT}/HDIAGS"
    HDIAGS_WORKDIR="${HDIAG_DIR}/vargroup1"
    VBAL_DIR="${ROOT}/VBAL"
    INPUT_DIR="${ROOT}/input"
    LOG_DIR="${ROOT}/logs"

    BG_FILE="${INPUT_DIR}/INIT.2026-05-12_12.F48.nc"
    TEMPLATE_FIELDS="${BG_FILE}"

    #===========================================================================
    # Validate fixed path values before loading any external environment
    #===========================================================================

    if [[ "${ROOT}" != "/scratch/lus/arw/jedi/mpas_only/3.0.3/24km" ]]; then
        fatal "unexpected ROOT: ${ROOT}"
        return 1
    fi

    if [[ "${HDIAGS_WORKDIR}" != "${ROOT}/HDIAGS/vargroup1" ]]; then
        fatal "unexpected HDIAGS work directory: ${HDIAGS_WORKDIR}"
        return 1
    fi

    #===========================================================================
    # Intel303 operational environment inherited from jedi.oper.sh
    #===========================================================================

    require_file "${MODEL_ENV}" || return 1
    require_file "${OPER_ENV}" || return 1

    source "${MODEL_ENV}" >/dev/null 2>&1
    source "${OPER_ENV}" >/dev/null 2>&1

    # Restore the fixed workflow variables after sourcing external environments.
    # This prevents modelenv.sh or switch_to_oper.sh from changing their values.
    VERSION="3.0.3"
    PARENT_ROOT="${HOME}/jedi/mpas_only/${VERSION}"
    ROOT="${PARENT_ROOT}/24km"

    GRID=1024002
    XNN="x1"
    NLEVELS=56
    MPAS_RESOLUTION=24

    MODEL_ROOT="/scratch/lus/arw/model"
    MPASJEDI_INSTALL="${HOME}/intel303/mpas-install"
    JEDI_EXE="${MPASJEDI_INSTALL}/bin/mpasjedi_error_covariance_toolbox.x"
    COMMON_RUNTIME="${PARENT_ROOT}/common_runtime.sh"

    MPAS_MESH_DIR="${MODEL_ROOT}/src/mpas/meshes/${MPAS_RESOLUTION}"
    INVARIANT="${MPAS_MESH_DIR}/${XNN}.${GRID}.invariant.nc"
    GRAPH_PREFIX="${MPAS_MESH_DIR}/${XNN}.${GRID}.graph.info.part."
    GRAPH_FILE="${GRAPH_PREFIX}${SLURM_NTASKS}"

    SAMPLES_UNBALANCED_DIR="${ROOT}/samplesUnbalanced"
    HDIAG_DIR="${ROOT}/HDIAGS"
    HDIAGS_WORKDIR="${HDIAG_DIR}/vargroup1"
    VBAL_DIR="${ROOT}/VBAL"
    INPUT_DIR="${ROOT}/input"
    LOG_DIR="${ROOT}/logs"

    BG_FILE="${INPUT_DIR}/INIT.2026-05-12_12.F48.nc"
    TEMPLATE_FIELDS="${BG_FILE}"

    export LD_LIBRARY_PATH="${MPASJEDI_INSTALL}/lib64:${MPASJEDI_INSTALL}/lib:${LD_LIBRARY_PATH:-}"

    export OMP_NUM_THREADS=1
    export HDF5_USE_FILE_LOCKING=FALSE
    export F_UFMTENDIAN='big:101-200'

    export MPICH_COLL_OPT_OFF=MPI_Scatterv
    export MPICH_COLL_SYNC=MPI_Gather
    export MPICH_RANK_REORDER_METHOD=0

    export OOPS_DEBUG="${OOPS_DEBUG:-0}"
    export OOPS_TRACE="${OOPS_TRACE:-0}"
    export OOPS_LOG_ALL_RANKS="${OOPS_LOG_ALL_RANKS:-0}"

    ulimit -s unlimited
    ulimit -c 0
    ulimit -v unlimited
    ulimit -d unlimited
    ulimit -m unlimited 2>/dev/null || true

    require_file "${COMMON_RUNTIME}" || return 1
    source "${COMMON_RUNTIME}"

    #===========================================================================
    # Validate required executable, mesh and VBAL products
    #===========================================================================

    mkdir -p "${LOG_DIR}" "${HDIAG_DIR}"

    if [[ ! -x "${JEDI_EXE}" ]]; then
        fatal "missing executable: ${JEDI_EXE}"
        return 1
    fi

    require_file "${INVARIANT}" || return 1
    require_file "${GRAPH_FILE}" || return 1

    require_file "${VBAL_DIR}/mpas_vbal.nc" || return 1
    require_file "${VBAL_DIR}/mpas_sampling.nc" || return 1

    require_dir "${SAMPLES_UNBALANCED_DIR}" || return 1
    require_dir "${INPUT_DIR}" || return 1

    require_file "${BG_FILE}" || return 1
    require_file "${TEMPLATE_FIELDS}" || return 1

    if ! command -v ncdump >/dev/null 2>&1; then
        fatal "ncdump is unavailable"
        return 1
    fi

    #===========================================================================
    # Detect completed VBAL-generated unbalanced samples
    #===========================================================================

    NMEMBERS=$(
        find "${SAMPLES_UNBALANCED_DIR}" \
            -maxdepth 1 \
            -type f \
            -name 'PTB_f48mf24_[0-9][0-9][0-9].nc' \
            -print |
        sort |
        wc -l
    )

    NMEMBERS=${NMEMBERS//[[:space:]]/}

    if [[ -z "${NMEMBERS}" ]] || (( NMEMBERS <= 1 )); then
        fatal "not enough unbalanced samples: ${NMEMBERS:-0}"
        return 1
    fi

    FIRST_SAMPLE=$(
        find "${SAMPLES_UNBALANCED_DIR}" \
            -maxdepth 1 \
            -type f \
            -name 'PTB_f48mf24_[0-9][0-9][0-9].nc' \
            -print |
        sort |
        head -1
    )

    require_file "${FIRST_SAMPLE}" || return 1

    SAMPLE_GRID=$(get_dimension "${FIRST_SAMPLE}" nCells)
    SAMPLE_LEVELS=$(get_dimension "${FIRST_SAMPLE}" nVertLevels)

    if [[ "${SAMPLE_GRID:-unknown}" != "${GRID}" ]]; then
        fatal "sample nCells=${SAMPLE_GRID:-unknown}; expected ${GRID}"
        return 1
    fi

    if [[ "${SAMPLE_LEVELS:-unknown}" != "${NLEVELS}" ]]; then
        fatal "sample nVertLevels=${SAMPLE_LEVELS:-unknown}; expected ${NLEVELS}"
        return 1
    fi

    # VBAL output perturbations may not contain xtime, Time or StrLen.
    # Their valid date is supplied explicitly in the HDIAGS YAML.

    #===========================================================================
    # Validate complete 24 km background/templateFields file
    #===========================================================================

    BG_GRID=$(get_dimension "${BG_FILE}" nCells)
    BG_LEVELS=$(get_dimension "${BG_FILE}" nVertLevels)
    BG_TIME=$(get_xtime "${BG_FILE}")

    if [[ "${BG_GRID:-unknown}" != "${GRID}" ]]; then
        fatal "background nCells=${BG_GRID:-unknown}; expected ${GRID}"
        return 1
    fi

    if [[ "${BG_LEVELS:-unknown}" != "${NLEVELS}" ]]; then
        fatal "background nVertLevels=${BG_LEVELS:-unknown}; expected ${NLEVELS}"
        return 1
    fi

    if [[ -z "${BG_TIME}" ]]; then
        fatal "could not determine time from background: ${BG_FILE}"
        return 1
    fi

    BASE=$(basename "${BG_FILE}")

    REF_DATE_TIME=$(
        echo "${BASE}" |
        sed -n \
            's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p'
    )

    if [[ -z "${REF_DATE_TIME}" ]]; then
        fatal "cannot parse REF_DATE_TIME from ${BASE}"
        return 1
    fi

    DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

    if [[ "${BG_TIME}" != "${REF_DATE_TIME}:00:00" ]]; then
        fatal \
            "background time ${BG_TIME} does not match " \
            "requested date ${REF_DATE_TIME}:00:00"
        return 1
    fi

    # Use a real VBAL-generated control-space perturbation as the output template.
    TEMPLATE="${FIRST_SAMPLE}"

    log "============================================================"
    log "24 km HDIAGS vargroup1 configuration"
    log "============================================================"
    log "Root                    : ${ROOT}"
    log "Work directory          : ${HDIAGS_WORKDIR}"
    log "Operational environment : ${OPER_ENV}"
    log "Intel installation      : ${MPASJEDI_INSTALL}"
    log "JEDI executable         : ${JEDI_EXE}"
    log "Grid                    : ${GRID}"
    log "Vertical levels         : ${NLEVELS}"
    log "Invariant               : ${INVARIANT}"
    log "Graph partition         : ${GRAPH_FILE}"
    log "MPI tasks               : ${SLURM_NTASKS}"
    log "Tasks per node          : ${SLURM_NTASKS_PER_NODE:-unknown}"
    log "CPUs per task           : ${SLURM_CPUS_PER_TASK:-unknown}"
    log "Unbalanced samples      : ${NMEMBERS}"
    log "First sample            : ${FIRST_SAMPLE}"
    log "Sample time metadata    : not required for VBAL outputs"
    log "Background              : ${BG_FILE}"
    log "Background xtime        : ${BG_TIME}"
    log "VBAL coefficients       : ${VBAL_DIR}/mpas_vbal.nc"
    log "VBAL sampling           : ${VBAL_DIR}/mpas_sampling.nc"
    log "============================================================"

    #===========================================================================
    # Safe cleanup of only the dedicated HDIAGS work directory
    #===========================================================================

    case "${HDIAGS_WORKDIR}" in
        "${ROOT}/HDIAGS/vargroup1")
            ;;
        *)
            fatal "refusing unsafe cleanup target: ${HDIAGS_WORKDIR}"
            return 1
            ;;
    esac

    if [[ "${HDIAGS_WORKDIR}" == "/" ]] ||
       [[ "${HDIAGS_WORKDIR}" == "/scratch" ]] ||
       [[ "${HDIAGS_WORKDIR}" == "/scratch/lus" ]] ||
       [[ "${HDIAGS_WORKDIR}" == "/scratch/lus/tmp" ]] ||
       [[ "${HDIAGS_WORKDIR}" == "${HOME}" ]]
    then
        fatal "refusing protected cleanup target: ${HDIAGS_WORKDIR}"
        return 1
    fi

    rm -rf -- "${HDIAGS_WORKDIR}"

    if [[ -e "${HDIAGS_WORKDIR}" ]]; then
        fatal "could not clean work directory: ${HDIAGS_WORKDIR}"
        return 1
    fi

    mkdir -p "${HDIAGS_WORKDIR}" || {
        fatal "cannot create work directory: ${HDIAGS_WORKDIR}"
        return 1
    }

    cd "${HDIAGS_WORKDIR}" || {
        fatal "cannot enter work directory: ${HDIAGS_WORKDIR}"
        return 1
    }

    #===========================================================================
    # Stage mesh, decomposition and runtime resources
    #===========================================================================

    ln -sfn ${GRAPH_PREFIX}* .

    ln -sfn \
        "${INVARIANT}" \
        "${XNN}.${GRID}.invariant.nc"

    ln -sfn \
        "${BG_FILE}" \
        "bg.${REF_DATE_TIME}.00.00.nc"

    ln -sfn \
        "${TEMPLATE_FIELDS}" \
        "templateFields.${GRID}.nc"

    ln -sfn \
        "${BG_FILE}" \
        background.nc

    ln -sfn "${TEMPLATE}" output.nc
    ln -sfn "${TEMPLATE}" control.nc
    ln -sfn "${TEMPLATE}" ensemble.nc

    stage_resources "${PWD}" || {
        fatal "failed to stage MPAS-JEDI runtime resources"
        return 1
    }

    write_streams "${PWD}" "${XNN}" "${GRID}" || {
        fatal "failed to write streams.atmosphere"
        return 1
    }

    require_file "${PWD}/streams.atmosphere" || return 1

    python3 - "${PWD}/streams.atmosphere" <<'PY_STREAM'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text()

marker = '<stream name="control"\n'

control_input_block = (
    '<stream name="control_input"\n'
    '        type="input"\n'
    '        precision="single"\n'
    '        io_type="pnetcdf,cdf5"\n'
    '        filename_template="control_input.nc"\n'
    '        input_interval="initial_only">\n'
    '        <file name="stream_list.atmosphere.control"/>\n'
    '</stream>\n'
    '\n'
)

if '<stream name="control_input"' not in content:
    if marker not in content:
        raise SystemExit(
            "FAILED: control output stream marker was not found"
        )

    content = content.replace(
        marker,
        control_input_block + marker,
        1,
    )

    path.write_text(content)

print("SUCCESS: control_input stream is configured")
PY_STREAM

    require_file "${PWD}/streams.atmosphere" || return 1

    #===========================================================================
    # Validate generated streams
    #===========================================================================

    if ! grep -F \
        "filename_template=\"${XNN}.${GRID}.invariant.nc\"" \
        "${PWD}/streams.atmosphere" >/dev/null 2>&1
    then
        fatal "invalid invariant filename in streams.atmosphere"
        return 1
    fi

    if ! grep -F \
        "filename_template=\"templateFields.${GRID}.nc\"" \
        "${PWD}/streams.atmosphere" >/dev/null 2>&1
    then
        fatal "invalid templateFields filename in streams.atmosphere"
        return 1
    fi

    if ! grep -A8 '<stream name="ensemble"' \
        "${PWD}/streams.atmosphere" |
        grep -F 'type="input"' >/dev/null 2>&1
    then
        fatal "ensemble stream is not configured as input"
        return 1
    fi

    if ! grep -A8 '<stream name="background"' \
        "${PWD}/streams.atmosphere" |
        grep -F 'type="input"' >/dev/null 2>&1
    then
        fatal "background stream is not configured as input"
        return 1
    fi

    if ! grep -A8 '<stream name="control"' \
        "${PWD}/streams.atmosphere" |
        grep -F 'type="output"' >/dev/null 2>&1
    then
        fatal "control stream is not configured as output"
        return 1
    fi

    #===========================================================================
    # MPAS geometry namelist for the 24 km mesh
    #===========================================================================

    cat > namelist.atmosphere <<EOF_NML
&nhyd_model
    config_time_integration_order = 2
    config_dt = 144.0
    config_start_time = '${REF_DATE_TIME}:00:00'
    config_run_duration = '0_06:00:00'
    config_split_dynamics_transport = true
    config_number_of_sub_steps = 2
    config_dynamics_split_steps = 3
    config_horiz_mixing = '2d_smagorinsky'
    config_len_disp = 24000.0
    config_scalar_advection = true
/
&io
    config_pio_num_iotasks = 0
    config_pio_stride = 1
/
&decomposition
    config_block_decomp_file_prefix = '${XNN}.${GRID}.graph.info.part.'
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

    require_file "${PWD}/namelist.atmosphere" || return 1

    #===========================================================================
    # HDIAGS vargroup1 YAML
    #
    # Input perturbations:
    #   ensemble stream, because common_runtime.sh defines it as input.
    #
    # Full background:
    #   background stream, because common_runtime.sh defines it as input.
    #
    # Diagnostic files:
    #   control stream, because common_runtime.sh defines it as output.
    #===========================================================================

    cat > run_hdiags.yaml <<EOF_YAML
_member config: &memberConfig
  state variables: &vars
  - stream_function
  - velocity_potential
  - temperature
  - spechum
  - surface_pressure
  date: &date '${DATE_STRING}'
  stream name: control_input
  transform model to analysis: false

geometry:
  nml_file: "./namelist.atmosphere"
  streams_file: "./streams.atmosphere"
  bump vunit: "avgheight"

background:
  state variables: *vars
  filename: "./bg.${REF_DATE_TIME}.00.00.nc"
  date: *date
  stream name: background
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

    require_file "${PWD}/run_hdiags.yaml" || return 1

    #===========================================================================
    # Validate YAML stream roles
    #===========================================================================

    if ! grep -A12 '^_member config:' \
        "${PWD}/run_hdiags.yaml" |
        grep -F 'stream name: control_input' >/dev/null 2>&1
    then
        fatal "input members do not use control_input stream"
        return 1
    fi

    if ! grep -A8 '^background:' \
        "${PWD}/run_hdiags.yaml" |
        grep -F 'stream name: background' >/dev/null 2>&1
    then
        fatal "background does not use background stream"
        return 1
    fi

    #===========================================================================
    # Run HDIAGS
    #===========================================================================

    log "Running HDIAGS vargroup1 with ${NMEMBERS} unbalanced samples"

    srun \
        -n "${SLURM_NTASKS}" \
        --cpu-bind=cores \
        "${JEDI_EXE}" \
        ./run_hdiags.yaml \
        ./run_hdiags.runlog

    JEDI_RC=$?

    if [[ "${JEDI_RC}" -ne 0 ]]; then
        fatal "HDIAGS vargroup1 returned code ${JEDI_RC}"
        return 1
    fi

    #===========================================================================
    # Validate outputs
    #===========================================================================

    require_file "${HDIAGS_WORKDIR}/mpas.stddev.nc" || return 1
    require_file "${HDIAGS_WORKDIR}/mpas.cor_rh.nc" || return 1
    require_file "${HDIAGS_WORKDIR}/mpas.cor_rv.nc" || return 1

    OUTPUT_GRID=$(
        get_dimension \
            "${HDIAGS_WORKDIR}/mpas.stddev.nc" \
            nCells
    )

    OUTPUT_LEVELS=$(
        get_dimension \
            "${HDIAGS_WORKDIR}/mpas.stddev.nc" \
            nVertLevels
    )

    if [[ "${OUTPUT_GRID:-unknown}" != "${GRID}" ]]; then
        fatal "STDDEV nCells=${OUTPUT_GRID:-unknown}; expected ${GRID}"
        return 1
    fi

    if [[ "${OUTPUT_LEVELS:-unknown}" != "${NLEVELS}" ]]; then
        fatal "STDDEV nVertLevels=${OUTPUT_LEVELS:-unknown}; expected ${NLEVELS}"
        return 1
    fi

    log "============================================================"
    log "DONE: HDIAGS vargroup1"
    log "STDDEV : ${HDIAGS_WORKDIR}/mpas.stddev.nc"
    log "COR_RH : ${HDIAGS_WORKDIR}/mpas.cor_rh.nc"
    log "COR_RV : ${HDIAGS_WORKDIR}/mpas.cor_rv.nc"
    log "Grid   : ${OUTPUT_GRID}"
    log "Levels : ${OUTPUT_LEVELS}"
    log "============================================================"

    return 0
}

main "$@"
