#!/bin/bash
#SBATCH --job-name=vbal_intel303_30km
#SBATCH --partition=opr
#SBATCH --nodes=48
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=4
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/3.0.3/30km/logs/vbal.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/3.0.3/30km/logs/vbal.out

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

    local SAMPLES_DIR
    local SAMPLES_UNBALANCED_DIR
    local VBAL_DIR
    local INPUT_DIR
    local LOG_DIR

    local NMEMBERS
    local FIRST_SAMPLE
    local BG_FILE
    local TEMPLATE
    local TEMPLATE_FIELDS

    local BASE
    local REF_DATE_TIME
    local DATE_STRING

    local SAMPLE_GRID
    local SAMPLE_LEVELS
    local SAMPLE_TIME
    local BG_GRID
    local BG_LEVELS
    local BG_TIME

    local JEDI_RC
    local OUT_COUNT
    local OUTPUT_GRID
    local OUTPUT_LEVELS

    #===========================================================================
    # Main paths
    #===========================================================================

    VERSION="3.0.3"

    PARENT_ROOT="${HOME}/jedi/mpas_only/${VERSION}"
    ROOT="${PARENT_ROOT}/30km"

    GRID=655362
    XNN="x1"
    NLEVELS=56
    MPAS_RESOLUTION=30

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

    SAMPLES_DIR="${ROOT}/samples"
    SAMPLES_UNBALANCED_DIR="${ROOT}/samplesUnbalanced"
    VBAL_DIR="${ROOT}/VBAL"
    INPUT_DIR="${ROOT}/input"
    LOG_DIR="${ROOT}/logs"

    #===========================================================================
    # Operational Intel303 environment inherited from jedi.oper.sh
    #===========================================================================

    require_file "${MODEL_ENV}" || return 1
    require_file "${OPER_ENV}" || return 1

    source "${MODEL_ENV}" >/dev/null 2>&1
    source "${OPER_ENV}" >/dev/null 2>&1

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
    # Validate installation, mesh and directories
    #===========================================================================

    mkdir -p \
        "${ROOT}" \
        "${LOG_DIR}" \
        "${VBAL_DIR}" \
        "${SAMPLES_UNBALANCED_DIR}"

    cd "${ROOT}" || {
        fatal "cannot enter ${ROOT}"
        return 1
    }

    if [[ ! -x "${JEDI_EXE}" ]]; then
        fatal "missing executable: ${JEDI_EXE}"
        return 1
    fi

    require_file "${INVARIANT}" || return 1
    require_file "${GRAPH_FILE}" || return 1

    require_dir "${SAMPLES_DIR}" || return 1
    require_dir "${INPUT_DIR}" || return 1

    #===========================================================================
    # Detect completed 30 km remapped samples
    #===========================================================================

    NMEMBERS=$(
        find "${SAMPLES_DIR}" \
            -maxdepth 1 \
            -type f \
            -name 'PTB_f48mf24_[0-9][0-9][0-9].nc' \
            -print |
        sort |
        wc -l
    )

    NMEMBERS=${NMEMBERS//[[:space:]]/}

    if [[ -z "${NMEMBERS}" ]] || (( NMEMBERS <= 1 )); then
        fatal "not enough completed samples in ${SAMPLES_DIR}: ${NMEMBERS:-0}"
        return 1
    fi

    FIRST_SAMPLE=$(
        find "${SAMPLES_DIR}" \
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

    SAMPLE_TIME=$(
        ncdump -v xtime "${FIRST_SAMPLE}" 2>/dev/null |
        sed -n \
            's/.*"\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p' |
        head -1
    )

    if [[ -z "${SAMPLE_TIME}" ]]; then
        fatal "cannot read xtime from ${FIRST_SAMPLE}"
        return 1
    fi

    log "Using ${NMEMBERS} remapped 30 km perturbation samples"

    #===========================================================================
    # Select complete remapped 30 km MPAS background
    #
    # Expected:
    #   ${ROOT}/input/INIT.YYYY-MM-DD_HH.F48.nc
    #===========================================================================

    BG_FILE=$(
        find "${INPUT_DIR}" \
            -maxdepth 2 \
            \( -type f -o -type l \) \
            -name 'INIT.*.F48.nc' \
            -print |
        sort |
        head -1
    )

    if [[ -z "${BG_FILE}" ]]; then
        fatal "no INIT.*.F48.nc background found under ${INPUT_DIR}"
        return 1
    fi

    require_file "${BG_FILE}" || return 1

    BG_GRID=$(get_dimension "${BG_FILE}" nCells)
    BG_LEVELS=$(get_dimension "${BG_FILE}" nVertLevels)

    if [[ "${BG_GRID:-unknown}" != "${GRID}" ]]; then
        fatal "background nCells=${BG_GRID:-unknown}; expected ${GRID}"
        return 1
    fi

    if [[ "${BG_LEVELS:-unknown}" != "${NLEVELS}" ]]; then
        fatal "background nVertLevels=${BG_LEVELS:-unknown}; expected ${NLEVELS}"
        return 1
    fi

    BG_TIME=$(
        ncdump -v xtime "${BG_FILE}" 2>/dev/null |
        sed -n \
            's/.*"\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p' |
        head -1
    )

    if [[ -z "${BG_TIME}" ]]; then
        fatal "cannot read xtime from ${BG_FILE}"
        return 1
    fi

    if [[ "${BG_TIME}" != "${SAMPLE_TIME}" ]]; then
        fatal "time mismatch: background=${BG_TIME}, samples=${SAMPLE_TIME}"
        return 1
    fi

    BASE=$(basename "${BG_FILE}")

    REF_DATE_TIME=$(
        echo "${BASE}" |
        sed -n \
            's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p'
    )

    if [[ -z "${REF_DATE_TIME}" ]]; then
        fatal "cannot parse reference date from ${BASE}"
        return 1
    fi

    DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

    if [[ "${SAMPLE_TIME}" != "${REF_DATE_TIME}:00:00" ]]; then
        fatal \
            "filename/YAML time ${REF_DATE_TIME}:00:00 does not match " \
            "sample xtime ${SAMPLE_TIME}"
        return 1
    fi

    TEMPLATE_FIELDS="${BG_FILE}"
    TEMPLATE="${FIRST_SAMPLE}"

    log "============================================================"
    log "30 km VBAL configuration"
    log "============================================================"
    log "Root                    : ${ROOT}"
    log "Model environment       : ${MODEL_ENV}"
    log "Operational environment : ${OPER_ENV}"
    log "Intel installation      : ${MPASJEDI_INSTALL}"
    log "JEDI executable         : ${JEDI_EXE}"
    log "Grid                    : ${GRID}"
    log "Vertical levels         : ${NLEVELS}"
    log "Invariant               : ${INVARIANT}"
    log "Graph partition         : ${GRAPH_FILE}"
    log "Samples directory       : ${SAMPLES_DIR}"
    log "Samples                 : ${NMEMBERS}"
    log "First sample            : ${FIRST_SAMPLE}"
    log "Sample xtime            : ${SAMPLE_TIME}"
    log "Background              : ${BG_FILE}"
    log "Background xtime        : ${BG_TIME}"
    log "Control template        : ${TEMPLATE}"
    log "Reference time          : ${REF_DATE_TIME}"
    log "JEDI date               : ${DATE_STRING}"
    log "MPI tasks               : ${SLURM_NTASKS}"
    log "Tasks per node          : ${SLURM_NTASKS_PER_NODE:-unknown}"
    log "CPUs per task           : ${SLURM_CPUS_PER_TASK:-unknown}"
    log "OMP threads             : ${OMP_NUM_THREADS}"
    log "============================================================"

    #===========================================================================
    # Recreate working/output directories
    #===========================================================================

    if [[ "${VBAL_DIR}" != "${ROOT}/VBAL" ]]; then
        fatal "refusing unsafe VBAL cleanup target: ${VBAL_DIR}"
        return 1
    fi

    if [[ "${SAMPLES_UNBALANCED_DIR}" != "${ROOT}/samplesUnbalanced" ]]; then
        fatal             "refusing unsafe unbalanced-sample cleanup target: "             "${SAMPLES_UNBALANCED_DIR}"
        return 1
    fi

    rm -rf -- "${VBAL_DIR}" "${SAMPLES_UNBALANCED_DIR}"

    mkdir -p \
        "${VBAL_DIR}" \
        "${SAMPLES_UNBALANCED_DIR}"

    cd "${VBAL_DIR}" || {
        fatal "cannot enter ${VBAL_DIR}"
        return 1
    }

    #===========================================================================
    # Mesh and decomposition
    #===========================================================================

    ln -sfn ${GRAPH_PREFIX}* .

    ln -sfn \
        "${INVARIANT}" \
        "${XNN}.${GRID}.invariant.nc"

    #===========================================================================
    # Background/template fields
    #===========================================================================

    ln -sfn \
        "${TEMPLATE_FIELDS}" \
        "templateFields.${GRID}.nc"

    ln -sfn \
        "${BG_FILE}" \
        "bg.${REF_DATE_TIME}.00.00.nc"

    ln -sfn \
        "${BG_FILE}" \
        background.nc

    # Templates used for control-space output.
    ln -sfn "${TEMPLATE}" output.nc
    ln -sfn "${TEMPLATE}" control.nc
    ln -sfn "${TEMPLATE}" ensemble.nc
    ln -sfn "${TEMPLATE}" control_input.nc

    stage_resources "${PWD}" || {
        fatal "failed to stage runtime resources"
        return 1
    }

    write_streams "${PWD}" "${XNN}" "${GRID}" || {
        fatal "failed to write streams.atmosphere"
        return 1
    }

    require_file "${PWD}/streams.atmosphere" || return 1

    python3 - "${PWD}/streams.atmosphere" <<'PY_STREAMS'
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text()

marker = '<stream name="control"\n'

control_input = (
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
            "FAILED: control output stream marker not found"
        )

    content = content.replace(
        marker,
        control_input + marker,
        1,
    )

    path.write_text(content)

print("SUCCESS: configured control_input stream")
PY_STREAMS

    require_file "${PWD}/streams.atmosphere" || return 1

    # Validate generated stream filenames and stream roles.
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

    if ! grep -A8 '<stream name="control"' \
        "${PWD}/streams.atmosphere" |
        grep -F 'type="output"' >/dev/null 2>&1
    then
        fatal "control stream is not configured as output"
        return 1
    fi

    #===========================================================================
    # MPAS geometry namelist
    #
    # 12 km values:
    #   config_dt       = 72 seconds
    #   config_len_disp = 12000 metres
    #
    # 30 km values:
    #   config_dt       = 180 seconds
    #   config_len_disp = 30000 metres
    #===========================================================================

    cat > namelist.atmosphere <<EOF_NML
&nhyd_model
    config_time_integration_order = 2
    config_dt = 180.0
    config_start_time = '${REF_DATE_TIME}:00:00'
    config_run_duration = '0_06:00:00'
    config_split_dynamics_transport = true
    config_number_of_sub_steps = 2
    config_dynamics_split_steps = 3
    config_horiz_mixing = '2d_smagorinsky'
    config_len_disp = 30000.0
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
    # VBAL YAML
    #
    # Input perturbations:
    #   stream name: control_input
    #
    # Output unbalanced perturbations:
    #   stream name: control
    #===========================================================================

    cat > run_vbal.yaml <<EOF_YAML
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

    require_file "${PWD}/run_vbal.yaml" || return 1

    # Validate input and output stream names before launching 768 ranks.
    if ! grep -A12 '^_member config:' "${PWD}/run_vbal.yaml" |
        grep -F 'stream name: control_input' >/dev/null 2>&1
    then
        fatal "input member configuration does not use ensemble stream"
        return 1
    fi

    if ! grep -A6 '^  output ensemble:' "${PWD}/run_vbal.yaml" |
        grep -F 'stream name: control' >/dev/null 2>&1
    then
        fatal "output ensemble configuration does not use control stream"
        return 1
    fi

    #===========================================================================
    # Run Intel303 VBAL
    #===========================================================================

    log "Running 30 km VBAL with ${NMEMBERS} samples"

    srun \
        -n "${SLURM_NTASKS}" \
        --cpu-bind=cores \
        "${JEDI_EXE}" \
        ./run_vbal.yaml \
        ./run_vbal.runlog

    JEDI_RC=$?

    if [[ "${JEDI_RC}" -ne 0 ]]; then
        fatal "VBAL executable returned code ${JEDI_RC}"
        return 1
    fi

    #===========================================================================
    # Validate results
    #===========================================================================

    require_file "${VBAL_DIR}/mpas_vbal.nc" || return 1
    require_file "${VBAL_DIR}/mpas_sampling.nc" || return 1

    OUT_COUNT=$(
        find "${SAMPLES_UNBALANCED_DIR}" \
            -maxdepth 1 \
            -type f \
            -name 'PTB_f48mf24_[0-9][0-9][0-9].nc' \
            -print |
        wc -l
    )

    OUT_COUNT=${OUT_COUNT//[[:space:]]/}

    if [[ "${OUT_COUNT}" -ne "${NMEMBERS}" ]]; then
        fatal "unbalanced sample count mismatch: ${OUT_COUNT} vs ${NMEMBERS}"
        return 1
    fi

    OUTPUT_GRID=$(
        get_dimension \
            "${SAMPLES_UNBALANCED_DIR}/PTB_f48mf24_001.nc" \
            nCells
    )

    OUTPUT_LEVELS=$(
        get_dimension \
            "${SAMPLES_UNBALANCED_DIR}/PTB_f48mf24_001.nc" \
            nVertLevels
    )

    if [[ "${OUTPUT_GRID:-unknown}" != "${GRID}" ]]; then
        fatal "unbalanced sample nCells=${OUTPUT_GRID:-unknown}; expected ${GRID}"
        return 1
    fi

    if [[ "${OUTPUT_LEVELS:-unknown}" != "${NLEVELS}" ]]; then
        fatal "unbalanced sample nVertLevels=${OUTPUT_LEVELS:-unknown}; expected ${NLEVELS}"
        return 1
    fi

    log "============================================================"
    log "DONE: Intel303 30 km VBAL completed"
    log "VBAL file          : ${VBAL_DIR}/mpas_vbal.nc"
    log "Sampling file      : ${VBAL_DIR}/mpas_sampling.nc"
    log "Unbalanced samples : ${OUT_COUNT}"
    log "Output nCells      : ${OUTPUT_GRID}"
    log "Output levels      : ${OUTPUT_LEVELS}"
    log "MPI tasks          : ${SLURM_NTASKS}"
    log "============================================================"

    return 0
}

main "$@"
