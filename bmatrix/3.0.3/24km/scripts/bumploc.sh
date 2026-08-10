#!/bin/bash
#SBATCH --job-name=bumploc24
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=02:00:00
#SBATCH --no-requeue
#SBATCH --exclusive
#SBATCH --export=NONE
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs/bumploc.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs/bumploc.out

set -x

#===============================================================================
# MPAS-JEDI 3.0.3
# 24-km BUMP/NICAS localization calibration
#
# Target mesh:
#   x1.1024002
#
# Operational environment:
#   /scratch/lus/arw/model/slurm/modelenv.sh
#   $HOME/spack-stack-oper/switch_to_oper.sh
#
# Background:
#   Permanent 24-km calibration state under $ROOT/input.
#
# Output:
#   $HOME/jedi/mpas_only/3.0.3/24km/BUMPLOC
#===============================================================================


#-------------------------------------------------------------------------------
# 1. Utility functions
#-------------------------------------------------------------------------------

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


date_shift() {
    local dh="$1"
    local base="$2"

    date -u \
        -d "${base:0:4}-${base:4:2}-${base:6:2} ${base:8:2}:00:00 ${dh} hours" \
        +%Y%m%d%H
}


#-------------------------------------------------------------------------------
# 2. Fixed 24-km configuration
#-------------------------------------------------------------------------------

VERSION=3.0.3

MPAS_RESOLUTION=24
GRID=1024002
XNN=x1

MPAS_DT=144.0
MPAS_DX=24000.0

MODEL_ROOT=/scratch/lus/arw/model
DAY_ROOT=/scratch/lus/tmp/arw/day
ASSIM_ROOT="$DAY_ROOT/assim"

ROOT="$HOME/jedi/mpas_only/$VERSION/24km"
BUMPLOC_DIR="$ROOT/BUMPLOC"
LOG_DIR="$ROOT/logs"

MPASJEDI_BUNDLE_ROOT="$HOME/intel303"
MPASJEDI_INSTALL="$MPASJEDI_BUNDLE_ROOT/mpas-install"
MPASJEDI_CODE="$MPASJEDI_BUNDLE_ROOT/code"
MPASJEDI_BUILD="$MPASJEDI_BUNDLE_ROOT/build"

JEDI_EXE="$MPASJEDI_INSTALL/bin/mpasjedi_error_covariance_toolbox.x"

JEDI_NAMELISTS="$MPASJEDI_CODE/mpas-jedi/test/testinput/namelists"

JEDI_OBSOP_NAME_MAP=\
"$MPASJEDI_CODE/mpas-jedi/test/testinput/obsop_name_map.yaml"

JEDI_PHYSICS_DIR="$MPASJEDI_BUILD/mpas-jedi/test"

MPAS_MESH_DIR="$MODEL_ROOT/src/mpas/meshes/24"

INVARIANT="$MPAS_MESH_DIR/x1.1024002.invariant.nc"

GRAPH_PREFIX="$MPAS_MESH_DIR/x1.1024002.graph.info.part."

BUMPLOC_PREFIX=mpas_bumploc

# Physical localization scales.
BUMPLOC_HLEN=1200.0e3
BUMPLOC_VLEN=6.0e3

# NICAS settings.
BUMPLOC_NICAS_RESOLUTION=8.0
BUMPLOC_COMP_GRID=4096


#-------------------------------------------------------------------------------
# 3. Load operational Intel MPAS-JEDI environment
#-------------------------------------------------------------------------------

source "$MODEL_ROOT/slurm/modelenv.sh" >/dev/null 2>&1

: "${START_DATE:?START_DATE is not defined by modelenv.sh}"

cd "$HOME/intel303" || \
    fatal "cannot enter $HOME/intel303"

source "$HOME/spack-stack-oper/switch_to_oper.sh" >/dev/null 2>&1

# The batch allocation starts with --export=NONE.
#
# switch_to_oper.sh has now constructed the controlled Intel/Spack runtime
# environment. All following srun job steps must inherit this environment.
export SLURM_EXPORT_ENV=ALL

export PATH="$MPASJEDI_INSTALL/bin:$PATH"

export LD_LIBRARY_PATH=\
"$MPASJEDI_INSTALL/lib64:$MPASJEDI_INSTALL/lib:${LD_LIBRARY_PATH:-}"

export OMP_NUM_THREADS=1

export HDF5_USE_FILE_LOCKING=FALSE
export F_UFMTENDIAN='big:101-200'

export MPICH_COLL_OPT_OFF=MPI_Scatterv
export MPICH_COLL_SYNC=MPI_Gather
export MPICH_RANK_REORDER_METHOD=0

export OOPS_DEBUG=0
export OOPS_TRACE=0
export OOPS_LOG_ALL_RANKS=0

ulimit -s unlimited
ulimit -c 0
ulimit -v unlimited
ulimit -d unlimited
ulimit -m unlimited 2>/dev/null || true


#-------------------------------------------------------------------------------
# 4. Validate executable, resources, mesh and graph
#-------------------------------------------------------------------------------

mkdir -p "$ROOT" "$LOG_DIR"

[ -x "$JEDI_EXE" ] || \
    fatal "missing executable: $JEDI_EXE"

require_dir "$MPAS_MESH_DIR"
require_file "$INVARIANT"

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

# MPAS appends the MPI-rank count to config_block_decomp_file_prefix.
GRAPH_FILE="${GRAPH_PREFIX}${SLURM_NTASKS}"

require_file "$GRAPH_FILE"

# Check executable shared libraries in the environment that will be propagated
# to the compute-node srun.
if ldd "$JEDI_EXE" 2>&1 | grep -q "not found"; then
    echo "ERROR: unresolved JEDI runtime libraries:" >&2
    ldd "$JEDI_EXE" >&2
    fatal "MPAS-JEDI runtime environment is incomplete"
fi

log "JEDI executable : $JEDI_EXE"
log "Resolution      : 24 km"
log "Grid            : $XNN.$GRID"
log "Invariant       : $INVARIANT"
log "Graph           : $GRAPH_FILE"
log "BUMPLOC output  : $BUMPLOC_DIR"


#-------------------------------------------------------------------------------
# 5. Permanent 24-km calibration background
#-------------------------------------------------------------------------------

INPUT_DIR="$ROOT/input"
BG_FILE="$INPUT_DIR/INIT.2026-05-12_12.F48.nc"

require_dir "$INPUT_DIR"
require_file "$BG_FILE"

BG_FILE_REAL="$(readlink -f "$BG_FILE")"

[ -n "$BG_FILE_REAL" ] || \
    fatal "cannot resolve calibration background: $BG_FILE"

require_file "$BG_FILE_REAL"

# This is a permanent calibration state, so its valid time is fixed.
REF_DATE_TIME="2026-05-12_12"
DATE_STRING="2026-05-12T12:00:00Z"
MPAS_START_TIME="2026-05-12_12:00:00"

log "Calibration background : $BG_FILE_REAL"
log "Reference date         : $REF_DATE_TIME"
log "MPAS start time        : $MPAS_START_TIME"
log "JEDI date              : $DATE_STRING"

#-------------------------------------------------------------------------------
# 6. Validate 24-km calibration geometry
#-------------------------------------------------------------------------------

BG_CELLS="$(
    ncdump -h "$BG_FILE_REAL" 2>/dev/null |
    awk '$1 == "nCells" && $2 == "=" {
        gsub(";", "", $3)
        print $3
        exit
    }'
)"

[ -n "$BG_CELLS" ] || \
    fatal "cannot determine nCells from $BG_FILE_REAL"

[ "$BG_CELLS" -eq "$GRID" ] || \
    fatal "background mesh mismatch: nCells=$BG_CELLS expected=$GRID"

log "Background nCells      : $BG_CELLS"

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
# 8. Recreate BUMPLOC working/output directory
#-------------------------------------------------------------------------------

rm -rf "$BUMPLOC_DIR"

mkdir -p "$BUMPLOC_DIR"

cd "$BUMPLOC_DIR" || \
    fatal "cannot enter $BUMPLOC_DIR"

# Only the graph required by this actual 768-rank calibration is staged.
ln -sfn \
    "$GRAPH_FILE" \
    "$(basename "$GRAPH_FILE")"

require_file "$(basename "$GRAPH_FILE")"

link_file \
    "$INVARIANT" \
    "${XNN}.${GRID}.invariant.nc"

link_file \
    "$BG_FILE_REAL" \
    background.nc

link_file \
    "$BG_FILE_REAL" \
    "mpasout.${REF_DATE_TIME}.00.00.nc"

link_file \
    "$BG_FILE_REAL" \
    "templateFields.${GRID}.nc"


#-------------------------------------------------------------------------------
# 9. Stage MPAS-JEDI resources
#-------------------------------------------------------------------------------

ln -sfn \
    "$JEDI_NAMELISTS/geovars.yaml" \
    geovars.yaml

ln -sfn \
    "$JEDI_NAMELISTS/keptvars.yaml" \
    keptvars.yaml

ln -sfn \
    "$JEDI_OBSOP_NAME_MAP" \
    obsop_name_map.yaml

for stream in analysis background control ensemble; do

    ln -sfn \
        "$JEDI_NAMELISTS/stream_list.atmosphere.$stream" \
        "stream_list.atmosphere.$stream"

done


# Physics/resource tables required by MPAS geometry initialization.

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
# 10. Write streams.atmosphere
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
# 11. Write namelist.atmosphere
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

grep -q \
    "config_start_time = '${MPAS_START_TIME}'" \
    namelist.atmosphere || \
    fatal "namelist start time was not rendered correctly"


#-------------------------------------------------------------------------------
# 12. Write BUMP/NICAS localization YAML
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
# 13. Validate rendered configuration before launching 768 ranks
#-------------------------------------------------------------------------------

if grep -q \
    '__[A-Z0-9_][A-Z0-9_]*__' \
    run_bumploc.yaml
then

    grep -n \
        '__[A-Z0-9_][A-Z0-9_]*__' \
        run_bumploc.yaml >&2

    fatal "unresolved placeholder remains in run_bumploc.yaml"

fi


# The date failure encountered previously must be caught here instead of after
# launching MPAS-JEDI.

grep -q \
    "date: &validDate '${DATE_STRING}'" \
    run_bumploc.yaml || \
    fatal "validDate was not rendered correctly"


case "$DATE_STRING" in
    ????-??-??T??:00:00Z)
        ;;
    *)
        fatal "invalid JEDI DATE_STRING: $DATE_STRING"
        ;;
esac


grep -q \
    "date: &validDate '....-..-..T..:00:00Z'" \
    run_bumploc.yaml || \
    fatal "invalid date in run_bumploc.yaml"


log "Pre-run date verification"

grep -n \
    "config_start_time" \
    namelist.atmosphere

grep -n \
    "date:" \
    run_bumploc.yaml |
    head -10


#-------------------------------------------------------------------------------
# 14. Configuration summary
#-------------------------------------------------------------------------------

log "============================================================"
log "24-km BUMPLOC calibration"
log "============================================================"
log "START_DATE       : $START_DATE"
log "JEDI valid date  : $DATE_STRING"
log "Mesh             : ${XNN}.${GRID}"
log "Invariant        : $INVARIANT"
log "Graph            : $GRAPH_FILE"
log "Background       : $BG_FILE_REAL"
log "Background cells : $BG_CELLS"
log "MPI ranks        : $SLURM_NTASKS"
log "CPUs per rank    : $SLURM_CPUS_PER_TASK"
log "OMP threads      : $OMP_NUM_THREADS"
log "Prefix           : $BUMPLOC_PREFIX"
log "Horizontal scale : $BUMPLOC_HLEN"
log "Vertical scale   : $BUMPLOC_VLEN"
log "NICAS resolution : $BUMPLOC_NICAS_RESOLUTION"
log "Computation grid : $BUMPLOC_COMP_GRID"
log "Output directory : $BUMPLOC_DIR"
log "============================================================"


#-------------------------------------------------------------------------------
# 15. Run BUMP/NICAS calibration
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


[ "$rc" -eq 0 ] || \
    fatal "BUMPLOC calibration failed with rc=$rc"


#-------------------------------------------------------------------------------
# 16. Validate generated BUMP localization files
#-------------------------------------------------------------------------------

shopt -s nullglob

bump_files=( "${BUMPLOC_PREFIX}"* )

loc_rh_files=( loc_rh.*.nc )
loc_rv_files=( loc_rv.*.nc )
norm_files=( nicas_norm.*.nc )
dirac_files=( dirac_nicas.*.nc )

shopt -u nullglob


[ "${#bump_files[@]}" -gt 0 ] || \
    fatal \
        "no BUMP localization files were created with prefix $BUMPLOC_PREFIX"


log "Generated ${#bump_files[@]} BUMP/NICAS files with prefix $BUMPLOC_PREFIX"


if [ "${#loc_rh_files[@]}" -eq 0 ]; then
    log "WARNING: no loc_rh diagnostic file was produced"
fi

if [ "${#loc_rv_files[@]}" -eq 0 ]; then
    log "WARNING: no loc_rv diagnostic file was produced"
fi

if [ "${#norm_files[@]}" -eq 0 ]; then
    log "WARNING: no nicas_norm diagnostic file was produced"
fi

if [ "${#dirac_files[@]}" -eq 0 ]; then
    log "WARNING: no dirac_nicas diagnostic file was produced"
fi


ls -lh \
    "${BUMPLOC_PREFIX}"* \
    loc_rh.*.nc \
    loc_rv.*.nc \
    nicas_norm.*.nc \
    dirac_nicas.*.nc \
    2>/dev/null || true


log "============================================================"
log "DONE: 24-km BUMPLOC calibration completed successfully"
log "BUMPLOC directory: $BUMPLOC_DIR"
log "Prefix           : $BUMPLOC_PREFIX"
log "============================================================"
