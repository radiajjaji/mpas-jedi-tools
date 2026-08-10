#!/bin/bash
#SBATCH --job-name=bumploc_oper303
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/3.0.3/logs/bumploc.%j.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/3.0.3/logs/bumploc.%j.err

set -x

#===============================================================================
# Operational Intel MPAS-JEDI 3.0.3 BUMP/NICAS localization calibration.
#
# Environment:
#   /scratch/lus/arw/model/slurm/modelenv.sh
#   $HOME/spack-stack-oper/switch_to_oper.sh
#
# Executable:
#   $HOME/intel303/mpas-install/bin/mpasjedi_error_covariance_toolbox.x
#
# Optional submission overrides:
#
#   sbatch \
#     --export=ALL,\
# BUMPLOC_BG_FILE=/scratch/lus/tmp/arw/day/assim/restart.2026-07-31_21:00:00.nc,\
# BUMPLOC_DATE=2026073121 \
#     bumploc.sh
#
# BUMPLOC_DATE accepts:
#   YYYYMMDDHH
#   YYYY-MM-DD_HH
#===============================================================================

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

fatal() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FATAL: $*" >&2
    return 1
}

require_file() {
    [ -s "$1" ] || fatal "missing or empty file: $1"
}

require_dir() {
    [ -d "$1" ] || fatal "missing directory: $1"
}

link_file() {
    local src="$1"
    local dst="$2"

    require_file "$src"
    ln -sfn "$src" "$dst"
    require_file "$dst"
}

#-------------------------------------------------------------------------------
# 1. Paths and calibration settings
#-------------------------------------------------------------------------------

VERSION="${VERSION:-3.0.3}"
ROOT="${ROOT:-$HOME/jedi/mpas_only/$VERSION}"

MODEL_ROOT="${MODEL_ROOT:-/scratch/lus/arw/model}"

MPASJEDI_BUNDLE_ROOT="${MPASJEDI_BUNDLE_ROOT:-$HOME/intel303}"
MPASJEDI_INSTALL="${MPASJEDI_INSTALL:-$MPASJEDI_BUNDLE_ROOT/mpas-install}"
MPASJEDI_CODE="${MPASJEDI_CODE:-$MPASJEDI_BUNDLE_ROOT/code}"
MPASJEDI_BUILD="${MPASJEDI_BUILD:-$MPASJEDI_BUNDLE_ROOT/build}"

JEDI_EXE="${JEDI_EXE:-$MPASJEDI_INSTALL/bin/mpasjedi_error_covariance_toolbox.x}"
JEDI_NAMELISTS="${JEDI_NAMELISTS:-$MPASJEDI_CODE/mpas-jedi/test/testinput/namelists}"
JEDI_OBSOP_NAME_MAP="${JEDI_OBSOP_NAME_MAP:-$MPASJEDI_CODE/mpas-jedi/test/testinput/obsop_name_map.yaml}"
JEDI_PHYSICS_DIR="${JEDI_PHYSICS_DIR:-$MPASJEDI_BUILD/mpas-jedi/test}"

GRID="${GRID:-4096002}"
MPAS_RESOLUTION="${MPAS_RESOLUTION:-12}"
XNN="${XNN:-x1}"

MPAS_MESH_DIR="${MPAS_MESH_DIR:-$MODEL_ROOT/src/mpas/meshes/$MPAS_RESOLUTION}"
INVARIANT="${INVARIANT:-$MPAS_MESH_DIR/${XNN}.${GRID}.invariant.nc}"
GRAPH_PREFIX="${GRAPH_PREFIX:-$MPAS_MESH_DIR/${XNN}.${GRID}.graph.info.part.}"

BUMPLOC_DIR="${BUMPLOC_DIR:-$ROOT/BUMPLOC}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"

BUMPLOC_PREFIX="${BUMPLOC_PREFIX:-mpas_bumploc}"
BUMPLOC_HLEN="${BUMPLOC_HLEN:-1200.0e3}"
BUMPLOC_VLEN="${BUMPLOC_VLEN:-6.0e3}"
BUMPLOC_NICAS_RESOLUTION="${BUMPLOC_NICAS_RESOLUTION:-8.0}"
BUMPLOC_COMP_GRID="${BUMPLOC_COMP_GRID:-4096}"

MPAS_DT="${MPAS_DT:-72.0}"
MPAS_DX="${MPAS_DX:-12000.0}"

#-------------------------------------------------------------------------------
# 2. Load the same operational Intel environment as jedi.oper.sh
#-------------------------------------------------------------------------------

source "$MODEL_ROOT/slurm/modelenv.sh" >/dev/null 2>&1
source "$HOME/spack-stack-oper/switch_to_oper.sh" >/dev/null 2>&1

export PATH="$MPASJEDI_INSTALL/bin:$PATH"
export LD_LIBRARY_PATH="$MPASJEDI_INSTALL/lib64:$MPASJEDI_INSTALL/lib:${LD_LIBRARY_PATH:-}"

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

#-------------------------------------------------------------------------------
# 3. Validate installation and resources
#-------------------------------------------------------------------------------

mkdir -p "$ROOT" "$LOG_DIR"

[ -x "$JEDI_EXE" ] || fatal "missing executable: $JEDI_EXE"

require_file "$INVARIANT"
require_dir "$MPAS_MESH_DIR"
require_dir "$JEDI_NAMELISTS"
require_file "$JEDI_OBSOP_NAME_MAP"

for resource in \
    geovars.yaml \
    keptvars.yaml \
    stream_list.atmosphere.analysis \
    stream_list.atmosphere.background \
    stream_list.atmosphere.control \
    stream_list.atmosphere.ensemble
do
    require_file "$JEDI_NAMELISTS/$resource"
done

log "JEDI executable : $JEDI_EXE"
log "Invariant       : $INVARIANT"
log "Graph prefix    : $GRAPH_PREFIX"
log "BUMPLOC output  : $BUMPLOC_DIR"

#-------------------------------------------------------------------------------
# 4. Select background file
#-------------------------------------------------------------------------------

if [ -n "${BUMPLOC_BG_FILE:-}" ]; then
    BG_FILE="$BUMPLOC_BG_FILE"
elif [ -d "$ROOT/background" ]; then
    BG_FILE="$(
        find "$ROOT/background" -type f \
            \( -name 'INIT.*.F48.nc' -o -name 'MPAS.*.nc' -o -name 'restart.*.nc' \) \
            | sort | head -1
    )"
elif [ -d "$ROOT/input/native_mpas_INIT_links" ]; then
    BG_FILE="$(
        find "$ROOT/input/native_mpas_INIT_links" \
            \( -type f -o -type l \) \
            \( -name 'INIT.*.F48.nc' -o -name 'MPAS.*.nc' -o -name 'restart.*.nc' \) \
            | sort | head -1
    )"
else
    fatal "no default background directory exists; set BUMPLOC_BG_FILE"
fi

require_file "$BG_FILE"

BG_FILE_REAL="$(readlink -f "$BG_FILE")"
require_file "$BG_FILE_REAL"

base="$(basename "$BG_FILE_REAL")"

#-------------------------------------------------------------------------------
# 5. Determine and validate reference date
#-------------------------------------------------------------------------------

REF_DATE_TIME=""

if [ -n "${BUMPLOC_DATE:-}" ]; then
    case "$BUMPLOC_DATE" in
        ??????????)
            REF_DATE_TIME="${BUMPLOC_DATE:0:4}-${BUMPLOC_DATE:4:2}-${BUMPLOC_DATE:6:2}_${BUMPLOC_DATE:8:2}"
            ;;
        ????-??-??_??)
            REF_DATE_TIME="$BUMPLOC_DATE"
            ;;
        *)
            fatal "BUMPLOC_DATE must be YYYYMMDDHH or YYYY-MM-DD_HH"
            ;;
    esac
else
    REF_DATE_TIME="$(
        printf '%s\n' "$base" |
        sed -n \
            -e 's/^INIT\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\..*\.nc$/\1/p' \
            -e 's/^MPAS\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\).*\.nc$/\1/p' \
            -e 's/^restart\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\):[0-9][0-9]:[0-9][0-9]\.nc$/\1/p' |
        head -1
    )"
fi

case "$REF_DATE_TIME" in
    ????-??-??_??) ;;
    *)
        fatal "cannot determine REF_DATE_TIME from '$base'; set BUMPLOC_DATE explicitly"
        ;;
esac

# Validate that GNU date accepts the parsed timestamp.
date -u -d "${REF_DATE_TIME/_/ }":00:00 +%Y%m%d%H >/dev/null 2>&1 || \
    fatal "invalid parsed date: $REF_DATE_TIME"

DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"
MPAS_START_TIME="${REF_DATE_TIME}:00:00"

log "Background file : $BG_FILE_REAL"
log "Background base : $base"
log "Reference date  : $REF_DATE_TIME"
log "MPAS start time : $MPAS_START_TIME"
log "JEDI date       : $DATE_STRING"

#-------------------------------------------------------------------------------
# 6. Recreate BUMPLOC work directory
#-------------------------------------------------------------------------------

rm -rf "$BUMPLOC_DIR"
mkdir -p "$BUMPLOC_DIR"
cd "$BUMPLOC_DIR" || fatal "cannot enter $BUMPLOC_DIR"

shopt -s nullglob
graph_files=( "${GRAPH_PREFIX}"* )
shopt -u nullglob

[ "${#graph_files[@]}" -gt 0 ] || fatal "no graph files match ${GRAPH_PREFIX}*"

for graph_file in "${graph_files[@]}"; do
    ln -sfn "$graph_file" .
done

link_file "$INVARIANT" "${XNN}.${GRID}.invariant.nc"
link_file "$BG_FILE_REAL" background.nc
link_file "$BG_FILE_REAL" "mpasout.${REF_DATE_TIME}.00.00.nc"
link_file "$BG_FILE_REAL" "templateFields.${GRID}.nc"

#-------------------------------------------------------------------------------
# 7. Stage Intel MPAS-JEDI resource files
#-------------------------------------------------------------------------------

ln -sfn "$JEDI_NAMELISTS/geovars.yaml" geovars.yaml
ln -sfn "$JEDI_NAMELISTS/keptvars.yaml" keptvars.yaml
ln -sfn "$JEDI_OBSOP_NAME_MAP" obsop_name_map.yaml

for stream in analysis background control ensemble; do
    ln -sfn \
        "$JEDI_NAMELISTS/stream_list.atmosphere.$stream" \
        "stream_list.atmosphere.$stream"
done

if [ -d "$JEDI_PHYSICS_DIR" ]; then
    for src in "$JEDI_PHYSICS_DIR"/*; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"

        case "$name" in
            *.TBL|*.DBL|RRTMG_*|RRTM_*|CAM_*|VERSION|COMPATIBILITY)
                ln -sfn "$src" "$name"
                ;;
        esac
    done
fi

for resource in \
    geovars.yaml \
    keptvars.yaml \
    obsop_name_map.yaml \
    stream_list.atmosphere.analysis \
    stream_list.atmosphere.background \
    stream_list.atmosphere.control \
    stream_list.atmosphere.ensemble \
    GENPARM.TBL \
    LANDUSE.TBL \
    SOILPARM.TBL \
    VEGPARM.TBL \
    RRTMG_LW_DATA \
    RRTMG_SW_DATA
do
    require_file "$resource"
done

#-------------------------------------------------------------------------------
# 8. Write streams.atmosphere
#-------------------------------------------------------------------------------

cat > streams.atmosphere <<EOF_STREAMS
<streams>

<immutable_stream name="invariant"
                  type="input"
                  precision="single"
                  filename_template="${XNN}.${GRID}.invariant.nc"
                  io_type="pnetcdf,cdf5"
                  input_interval="initial_only" />

<immutable_stream name="input"
                  type="input"
                  precision="single"
                  filename_template="templateFields.${GRID}.nc"
                  io_type="pnetcdf,cdf5"
                  input_interval="initial_only" />

<immutable_stream name="da_state"
                  type="output"
                  precision="single"
                  io_type="pnetcdf,cdf5"
                  filename_template="mpasout.\$Y-\$M-\$D_\$h.\$m.\$s.nc"
                  packages="jedi_da"
                  output_interval="none"
                  clobber_mode="overwrite" />

<stream name="background"
        type="input"
        precision="single"
        io_type="pnetcdf,cdf5"
        filename_template="background.nc"
        input_interval="initial_only">
        <file name="stream_list.atmosphere.background"/>
</stream>

<stream name="ensemble"
        type="input"
        precision="single"
        io_type="pnetcdf,cdf5"
        filename_template="ensemble.nc"
        input_interval="initial_only">
        <file name="stream_list.atmosphere.ensemble"/>
</stream>

<stream name="analysis"
        type="output"
        precision="single"
        io_type="pnetcdf,cdf5"
        filename_template="analysis.nc"
        output_interval="none"
        clobber_mode="overwrite">
        <file name="stream_list.atmosphere.analysis"/>
</stream>

<stream name="control"
        type="output"
        precision="single"
        io_type="pnetcdf,cdf5"
        filename_template="control.nc"
        output_interval="initial_only"
        clobber_mode="overwrite">
        <file name="stream_list.atmosphere.control"/>
</stream>

<stream name="output"
        type="none"
        filename_template="output.nc"
        output_interval="0_01:00:00" />

<stream name="diagnostics"
        type="none"
        filename_template="diagnostics.nc"
        output_interval="0_01:00:00" />

</streams>
EOF_STREAMS

require_file streams.atmosphere

#-------------------------------------------------------------------------------
# 9. Write namelist.atmosphere
#-------------------------------------------------------------------------------

cat > namelist.atmosphere <<EOF_NML
&nhyd_model
    config_time_integration_order = 2
    config_dt = ${MPAS_DT}
    config_start_time = '${MPAS_START_TIME}'
    config_run_duration = '0_00:00:00'
    config_split_dynamics_transport = true
    config_number_of_sub_steps = 2
    config_dynamics_split_steps = 3
    config_horiz_mixing = '2d_smagorinsky'
    config_len_disp = ${MPAS_DX}
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

require_file namelist.atmosphere

grep -q "config_start_time = '${MPAS_START_TIME}'" namelist.atmosphere || \
    fatal "namelist start time was not rendered correctly"

#-------------------------------------------------------------------------------
# 10. Write BUMP/NICAS localization YAML
#-------------------------------------------------------------------------------

cat > run_bumploc.yaml <<EOF_YAML
_output config: &outputConfig
  date: &validDate '${DATE_STRING}'
  stream name: control

geometry:
  nml_file: "./namelist.atmosphere"
  streams_file: "./streams.atmosphere"
  deallocate non-da fields: true
  bump vunit: "height"

background:
  state variables: &vars
  - temperature
  - spechum
  - uReconstructZonal
  - uReconstructMeridional
  - surface_pressure
  filename: "./background.nc"
  date: *validDate
  stream name: background

background error:
  covariance model: SABER

  saber central block:
    saber block name: BUMP_NICAS
    active variables: *vars

    calibration:
      io:
        files prefix: ${BUMPLOC_PREFIX}

      drivers:
        multivariate strategy: duplicated
        compute nicas: true
        write local nicas: true
        write global nicas: true
        write nicas grids: true
        internal dirac test: true

      model:
        nearest 3d level: bottom

      grids:
      - model:
          variables:
          - temperature
          - spechum
          - uReconstructZonal
          - uReconstructMeridional
          nearest 3d level: bottom

      - model:
          variables:
          - surface_pressure
          nearest 3d level: bottom

      sampling:
        computation grid size: ${BUMPLOC_COMP_GRID}

      nicas:
        resolution: ${BUMPLOC_NICAS_RESOLUTION}
        explicit length-scales: true

        horizontal length-scale:
        - groups: [common]
          value: ${BUMPLOC_HLEN}

        vertical length-scale:
        - groups: [common]
          value: ${BUMPLOC_VLEN}

      dirac:
      - {longitude: -135.0, latitude: -45.0, level: 1, variable: temperature}
      - {longitude:  -45.0, latitude: -45.0, level: 1, variable: temperature}
      - {longitude:   45.0, latitude: -45.0, level: 1, variable: temperature}
      - {longitude:  135.0, latitude: -45.0, level: 1, variable: temperature}
      - {longitude: -135.0, latitude:   0.0, level: 1, variable: temperature}
      - {longitude:  -45.0, latitude:   0.0, level: 1, variable: temperature}
      - {longitude:   45.0, latitude:   0.0, level: 1, variable: temperature}
      - {longitude:  135.0, latitude:   0.0, level: 1, variable: temperature}
      - {longitude: -135.0, latitude:  45.0, level: 1, variable: temperature}
      - {longitude:  -45.0, latitude:  45.0, level: 1, variable: temperature}
      - {longitude:   45.0, latitude:  45.0, level: 1, variable: temperature}
      - {longitude:  135.0, latitude:  45.0, level: 1, variable: temperature}

      output model files:
      - parameter: loc_rh
        file:
          filename: ./loc_rh.\$Y-\$M-\$D_\$h.\$m.\$s.nc
          <<: *outputConfig

      - parameter: loc_rv
        file:
          filename: ./loc_rv.\$Y-\$M-\$D_\$h.\$m.\$s.nc
          <<: *outputConfig

      - parameter: nicas_norm
        file:
          filename: ./nicas_norm.\$Y-\$M-\$D_\$h.\$m.\$s.nc
          <<: *outputConfig

      - parameter: dirac_nicas
        file:
          filename: ./dirac_nicas.\$Y-\$M-\$D_\$h.\$m.\$s.nc
          <<: *outputConfig
EOF_YAML

require_file run_bumploc.yaml

#-------------------------------------------------------------------------------
# 11. Final pre-run validation
#-------------------------------------------------------------------------------

if grep -q '__[A-Z0-9_][A-Z0-9_]*__' run_bumploc.yaml; then
    grep -n '__[A-Z0-9_][A-Z0-9_]*__' run_bumploc.yaml >&2 || true
    fatal "unresolved placeholder remains in run_bumploc.yaml"
fi

log "Pre-run date verification:"
grep -n "config_start_time" namelist.atmosphere
grep -n "date:" run_bumploc.yaml | head

log "Launching Intel MPAS-JEDI BUMPLOC calibration"
log "MPI ranks        : $SLURM_NTASKS"
log "CPUs per rank    : $SLURM_CPUS_PER_TASK"
log "Prefix           : $BUMPLOC_PREFIX"
log "Horizontal scale : $BUMPLOC_HLEN"
log "Vertical scale   : $BUMPLOC_VLEN"
log "NICAS resolution : $BUMPLOC_NICAS_RESOLUTION"
log "Computation grid : $BUMPLOC_COMP_GRID"

#-------------------------------------------------------------------------------
# 12. Run calibration
#-------------------------------------------------------------------------------

set +e
srun \
    --label \
    --cpu-bind=cores \
    -n "$SLURM_NTASKS" \
    --cpus-per-task="$SLURM_CPUS_PER_TASK" \
    "$JEDI_EXE" \
    ./run_bumploc.yaml \
    ./run_bumploc.runlog
rc=$?
set -e

[ "$rc" -eq 0 ] || fatal "BUMPLOC calibration failed with rc=$rc"

#-------------------------------------------------------------------------------
# 13. Validate outputs
#-------------------------------------------------------------------------------

shopt -s nullglob
bump_files=( "${BUMPLOC_PREFIX}"* )
shopt -u nullglob

[ "${#bump_files[@]}" -gt 0 ] || \
    fatal "no BUMP localization files were created with prefix $BUMPLOC_PREFIX"

log "Generated BUMPLOC products:"

ls -lh \
    "${BUMPLOC_PREFIX}"* \
    loc_rh.*.nc \
    loc_rv.*.nc \
    nicas_norm.*.nc \
    dirac_nicas.*.nc \
    2>/dev/null || true

log "DONE: $BUMPLOC_DIR"
