#!/bin/bash
#
# MPAS-JEDI 4.0.0 GNU NICAS generation for remapped 24-km / 30-km B matrices.
#
# Usage:
#
#   sbatch nicas.sh
#
# This is the fixed 24-km version.
# All supported NICAS variables are processed sequentially.
# No MPAS_RESOLUTION or NICAS_VAR needs to be exported.
#
# Variables:
#   stream_function
#   velocity_potential
#   temperature
#   spechum
#   surface_pressure
#   qc
#   qi
#   qr
#   qs
#   qg
#
#SBATCH --job-name=nicas_gnu400
#SBATCH --partition=opr
#SBATCH --nodes=48
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=16
#SBATCH --cpus-per-task=4
#SBATCH --threads-per-core=1
#SBATCH --time=06:00:00
#SBATCH --output=logs/nicas.out
#SBATCH --error=logs/nicas.out

set -euo pipefail
set -x

# =============================================================================
# Helpers
# =============================================================================

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
        fatal "missing or empty required file: $1"
        return 1
    fi
}

require_dir()
{
    if [[ ! -d "$1" ]]; then
        fatal "missing required directory: $1"
        return 1
    fi
}

# =============================================================================
# Configuration
# =============================================================================

main()
{
    local VERSION
    local PARENT_ROOT
    local ROOT
    local GRID
    local XNN
    local NLEVELS

    local MODEL_ROOT
    local MPAS_MESH_DIR
    local INVARIANT
    local GRAPH_PREFIX
    local GRAPH_FILE

    local JEDI_INSTALL
    local JEDI_EXE

    local HDIAG_DIR
    local NICAS_DIR
    local LOG_DIR
    local INPUT_DIR

    local BG_FILE
    local TEMPLATE_FIELDS
    local REF_DATE_TIME
    local DATE_STRING

    local MPAS_VAR
    local JEDI_VAR
    local variable
    local variable_dir

    local nc1max
    local resolution
    local hydrometeor_nicas_yaml
    local vert_level_dirac

    local rc
    local nlocal
    local ngrids

    VERSION=3.0.3
    PARENT_ROOT="${HOME}/jedi/mpas_only/${VERSION}"

    XNN=x1
    NLEVELS=56

    # -------------------------------------------------------------------------
    # Fixed 24-km configuration.
    #
    # Nothing needs to be exported from the submission shell.
    # NICAS_VAR is assigned internally by the driver at the end of this script.
    # -------------------------------------------------------------------------

    MPAS_RESOLUTION=24
    ROOT="${PARENT_ROOT}/24km"
    GRID=1024002

    # -------------------------------------------------------------------------
    # 24/30-km data belong to the 3.0.3 B-matrix tree.
    # The executable/runtime used to CALCULATE NICAS is GNU MPAS-JEDI 4.0.0.
    # -------------------------------------------------------------------------

    MODEL_ROOT=/scratch/lus/arw/model
    MPAS_MESH_DIR="${MODEL_ROOT}/src/mpas/meshes/${MPAS_RESOLUTION}"

    INVARIANT="${MPAS_MESH_DIR}/${XNN}.${GRID}.invariant.nc"
    GRAPH_PREFIX="${MPAS_MESH_DIR}/${XNN}.${GRID}.graph.info.part."
    GRAPH_FILE="${GRAPH_PREFIX}${SLURM_NTASKS}"

    HDIAG_DIR="${ROOT}/HDIAGS"
    NICAS_DIR="${ROOT}/NICAS"
    LOG_DIR="${ROOT}/logs"
    INPUT_DIR="${ROOT}/input"

    # -------------------------------------------------------------------------
    # GNU MPAS-JEDI 4.0.0 installation
    #
    # Keep these as fixed values: do NOT allow an inherited Intel303/other
    # environment to silently redirect the executable.
    # -------------------------------------------------------------------------

    JEDI_INSTALL="${HOME}/gnu400/mpas-install"
    JEDI_EXE="${JEDI_INSTALL}/bin/mpasjedi_error_covariance_toolbox.x"

    # -------------------------------------------------------------------------
    # Native MPAS name versus JEDI/SABER name.
    #
    # HDIAGS files stay completely untouched.
    # Only hydrometeors require the established JEDI/SABER name translation.
    # -------------------------------------------------------------------------

    MPAS_VAR="${NICAS_VAR}"

    case "${NICAS_VAR}" in
        qc)
            JEDI_VAR=cloud_liquid_water
            ;;
        qi)
            JEDI_VAR=cloud_liquid_ice
            ;;
        qr)
            JEDI_VAR=rain_water
            ;;
        qs)
            JEDI_VAR=snow_water
            ;;
        qg)
            JEDI_VAR=graupel
            ;;
        *)
            JEDI_VAR="${NICAS_VAR}"
            ;;
    esac

    variable_dir="${MPAS_VAR}"
    variable="${JEDI_VAR}"

    # -------------------------------------------------------------------------
    # Preserve the proven 4.0.0 NICAS settings.
    # -------------------------------------------------------------------------

    nc1max=15000
    resolution=8
    hydrometeor_nicas_yaml=""

    case "${NICAS_VAR}" in
        qc|qi|qr|qs|qg)
            nc1max=60000
            resolution=4

            hydrometeor_nicas_yaml="$(cat <<EOF_HYDRO
        explicit length-scales: true
        horizontal length-scale:
        - groups:
          - ${JEDI_VAR}
          value: 300.0e3
EOF_HYDRO
)"
            ;;
    esac

    # =========================================================================
    # GNU 4.0.0 operational environment
    # =========================================================================

    set +x
    set +e

    # Use the SAME GNU400 environment loader used by the successful native
    # 4.0.0 workflow.
    GNU_ENV="${HOME}/spack-stack-1.9.3-gnu/switch_to_gnu.sh"

    if [[ ! -f "${GNU_ENV}" ]]; then
        fatal "GNU environment script not found: ${GNU_ENV}"
        return 1
    fi

    log "Loading GNU MPAS-JEDI 4.0.0 runtime environment"
    source "${GNU_ENV}" || {
        fatal "failed to load GNU environment: ${GNU_ENV}"
        return 1
    }

    if [[ ! -x "${JEDI_EXE}" ]]; then
        fatal "GNU400 MPAS-JEDI executable not found: ${JEDI_EXE}"
        return 1
    fi
    env_rc=$?

    set -e
    set -x

    if [[ "${env_rc}" -ne 0 ]]; then
        log "WARNING: GNU400 environment loader returned rc=${env_rc}"
    fi

    export LD_LIBRARY_PATH="${JEDI_INSTALL}/lib:${JEDI_INSTALL}/lib64:${LD_LIBRARY_PATH:-}"

    export OMP_NUM_THREADS=1
    export OOPS_NUM_THREADS=1
    export HDF5_USE_FILE_LOCKING=FALSE

    require_file "${JEDI_EXE}" || return 1

    if ldd "${JEDI_EXE}" | grep -q 'not found'; then
        ldd "${JEDI_EXE}" | grep 'not found' >&2
        fatal "unresolved shared libraries for ${JEDI_EXE}"
        return 1
    fi

    # =========================================================================
    # Required 3.0.3 resources
    # =========================================================================

    require_dir "${ROOT}" || return 1
    require_dir "${HDIAG_DIR}/merge" || return 1
    require_dir "${INPUT_DIR}" || return 1

    require_file "${HDIAG_DIR}/merge/mpas.cor_rh.nc" || return 1
    require_file "${HDIAG_DIR}/merge/mpas.cor_rv.nc" || return 1
    require_file "${HDIAG_DIR}/merge/mpas.stddev.nc" || return 1

    require_file "${INVARIANT}" || return 1
    require_file "${GRAPH_FILE}" || return 1

    # =========================================================================
    # Background
    # =========================================================================

    BG_FILE=$(
        find "${INPUT_DIR}" \
            -maxdepth 1 \
            -type f \
            -name 'INIT.*.F48.nc' \
            -print |
        sort |
        head -1
    )

    require_file "${BG_FILE}" || return 1

    REF_DATE_TIME=$(
        basename "${BG_FILE}" |
        sed -n \
            's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.F48\.nc$/\1/p'
    )

    if [[ -z "${REF_DATE_TIME}" ]]; then
        fatal "cannot determine REF_DATE_TIME from ${BG_FILE}"
        return 1
    fi

    DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"
    TEMPLATE_FIELDS="${BG_FILE}"

    # =========================================================================
    # Runtime information
    # =========================================================================

    mkdir -p "${LOG_DIR}"
    mkdir -p "${NICAS_DIR}"

    log "============================================================"
    log "GNU MPAS-JEDI 4.0.0 NICAS"
    log "============================================================"
    log "Target B-matrix tree    : ${ROOT}"
    log "MPAS resolution         : ${MPAS_RESOLUTION} km"
    log "GRID                    : ${GRID}"
    log "Vertical levels         : ${NLEVELS}"
    log "JEDI installation       : ${JEDI_INSTALL}"
    log "JEDI executable         : ${JEDI_EXE}"
    log "Invariant               : ${INVARIANT}"
    log "Graph file              : ${GRAPH_FILE}"
    log "HDIAGS directory        : ${HDIAG_DIR}/merge"
    log "NICAS directory         : ${NICAS_DIR}/${variable_dir}"
    log "Background              : ${BG_FILE}"
    log "Reference time          : ${REF_DATE_TIME}"
    log "MPAS/HDIAGS variable    : ${MPAS_VAR}"
    log "JEDI/SABER variable     : ${JEDI_VAR}"
    log "NICAS resolution        : ${resolution}"
    log "NICAS nc1max            : ${nc1max}"
    log "MPI tasks               : ${SLURM_NTASKS}"
    log "============================================================"

    # =========================================================================
    # Prepare ONLY this variable's NICAS directory.
    #
    # IMPORTANT:
    # Never remove ROOT, /scratch/lus/tmp, HDIAGS, input, samples, etc.
    # =========================================================================

    if [[ "${NICAS_DIR}" != "${ROOT}/NICAS" ]]; then
        fatal "NICAS_DIR safety check failed: ${NICAS_DIR}"
        return 1
    fi

    TARGET_DIR="${NICAS_DIR}/${variable_dir}"

    case "${TARGET_DIR}" in
        "${NICAS_DIR}"/*)
            rm -rf -- "${TARGET_DIR}"
            ;;
        *)
            fatal "refusing unsafe NICAS removal: ${TARGET_DIR}"
            return 1
            ;;
    esac
    mkdir -p "${NICAS_DIR}/${variable_dir}"

    cd "${NICAS_DIR}/${variable_dir}"

    # =========================================================================
    # MPAS resources
    # =========================================================================

    ln -sfn "${GRAPH_FILE}" .
    ln -sfn "${INVARIANT}" "${XNN}.${GRID}.invariant.nc"

    ln -sfn "${BG_FILE}" "bg.${REF_DATE_TIME}.00.00.nc"
    ln -sfn "${BG_FILE}" background.nc

    ln -sfn "${TEMPLATE_FIELDS}" "templateFields.${GRID}.nc"
    ln -sfn "${TEMPLATE_FIELDS}" output.nc
    ln -sfn "${TEMPLATE_FIELDS}" control.nc
    ln -sfn "${TEMPLATE_FIELDS}" ensemble.nc

    # =========================================================================
    # Runtime resources
    #
    # Use the common runtime from the working GNU400 installation/tree.
    # =========================================================================

    require_file "${HOME}/jedi/mpas_only/4.0.0/common_runtime.sh" || return 1

    source "${HOME}/jedi/mpas_only/4.0.0/common_runtime.sh"

    stage_resources "${PWD}" ||
    {
        fatal "failed to stage GNU MPAS-JEDI 4.0.0 runtime resources"
        return 1
    }

    write_streams "${PWD}" "${GRID}" ||
    {
        fatal "failed to write streams.atmosphere"
        return 1
    }

    # Same control stream used by the successful 4.0.0 NICAS.
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

    # =========================================================================
    # HDIAGS products
    #
    # IMPORTANT: these remain native MPAS names.
    # =========================================================================

    ln -sfn "${HDIAG_DIR}/merge/mpas.cor_rh.nc" mpas.cor_rh.nc
    ln -sfn "${HDIAG_DIR}/merge/mpas.cor_rv.nc" mpas.cor_rv.nc
    ln -sfn "${HDIAG_DIR}/merge/mpas.stddev.nc" mpas.stddev.nc

    if [[ "${variable}" == "surface_pressure" ]]; then
        vert_level_dirac=1
    else
        vert_level_dirac=36
    fi

    # =========================================================================
    # MPAS namelist
    # =========================================================================

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

    # =========================================================================
    # NICAS YAML
    # =========================================================================

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
        reduced levels: ${NLEVELS}
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

    # =========================================================================
    # Final checks
    # =========================================================================

    require_file namelist.atmosphere || return 1
    require_file streams.atmosphere || return 1
    require_file stream_list.atmosphere.control || return 1
    require_file run_nicas.yaml || return 1

    log "Starting GNU400 NICAS for ${MPAS_RESOLUTION}km / ${NICAS_VAR}"

    # =========================================================================
    # Execute
    # =========================================================================

    set +e

    srun \
        -n "${SLURM_NTASKS}" \
        --cpu-bind=cores \
        "${JEDI_EXE}" \
        ./run_nicas.yaml \
        ./run_nicas.runlog

    rc=$?

    set -e

    if [[ "${rc}" -ne 0 ]]; then
        log "WARNING: srun returned rc=${rc}; checking products"
    fi

    # =========================================================================
    # Validate
    # =========================================================================

    require_file mpas_nicas.nc || return 1
    require_file mpas.nicas_norm.nc || return 1
    require_file mpas.dirac_nicas.nc || return 1

    if ! compgen -G 'mpas_nicas_local_*.nc' >/dev/null; then
        fatal "missing mpas_nicas_local_*.nc for ${variable}"
        return 1
    fi

    if ! compgen -G 'mpas_nicas_grids_local_*.nc' >/dev/null; then
        fatal "missing mpas_nicas_grids_local_*.nc for ${variable}"
        return 1
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

    if [[ "${nlocal}" -ne "${SLURM_NTASKS}" ]]; then
        fatal "expected ${SLURM_NTASKS} local NICAS files; found ${nlocal}"
        return 1
    fi

    if [[ "${ngrids}" -ne "${SLURM_NTASKS}" ]]; then
        fatal "expected ${SLURM_NTASKS} local NICAS grid files; found ${ngrids}"
        return 1
    fi

    log "============================================================"
    log "NICAS completed successfully"
    log "Target                  : ${MPAS_RESOLUTION} km"
    log "Native MPAS variable    : ${MPAS_VAR}"
    log "JEDI/SABER variable     : ${JEDI_VAR}"
    log "Global NICAS            : ${PWD}/mpas_nicas.nc"
    log "Normalization           : ${PWD}/mpas.nicas_norm.nc"
    log "Dirac diagnostic        : ${PWD}/mpas.dirac_nicas.nc"
    log "Local NICAS files       : ${nlocal}"
    log "Local grid files        : ${ngrids}"
    log "============================================================"

    return 0
}

# =============================================================================
# NICAS driver
#
# Process the complete B-matrix variable set sequentially.
# No submission-shell variables are required.
# =============================================================================

NICAS_VARIABLES=(
    stream_function
    velocity_potential
    temperature
    spechum
    surface_pressure
    qc
    qi
    qr
    qs
    qg
)

log "============================================================"
log "Starting complete 24-km GNU400 NICAS generation"
log "Variables: ${NICAS_VARIABLES[*]}"
log "============================================================"

for NICAS_VAR in "${NICAS_VARIABLES[@]}"
do
    log ""
    log "############################################################"
    log "Starting NICAS variable: ${NICAS_VAR}"
    log "############################################################"

    if ! main; then
        fatal "NICAS failed for ${NICAS_VAR}"
        return 1 2>/dev/null || false
    fi

    log "Completed NICAS variable: ${NICAS_VAR}"
done

log ""
log "============================================================"
log "ALL 24-km NICAS VARIABLES COMPLETED SUCCESSFULLY"
log "============================================================"
log "Output root: ${HOME}/jedi/mpas_only/3.0.3/24km/NICAS"
log "============================================================"
