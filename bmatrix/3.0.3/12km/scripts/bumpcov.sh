#!/bin/bash
#SBATCH --job-name=bumpcov_ensgen303
#SBATCH --partition=opr
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --threads-per-core=1
#SBATCH --time=08:00:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/3.0.3/logs/bumpcov_ensgen.%j.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/3.0.3/logs/bumpcov_ensgen.%j.err

set -euo pipefail
set -x

log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
fail(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] FAILED: $*" >&2; false; }
require_file(){ [ -s "$1" ] || fail "missing or empty file: $1"; }
require_dir(){ [ -d "$1" ] || fail "missing directory: $1"; }
var_exists(){ ncdump -h "$1" 2>/dev/null | grep -Eq "[[:space:]](float|double)[[:space:]]+$2[(:]"; }

VERSION="${VERSION:-3.0.3}"
ROOT="${ROOT:-$HOME/jedi/mpas_only/$VERSION}"
MODEL_ROOT="${MODEL_ROOT:-/scratch/lus/arw/model}"

MPASJEDI_ROOT="${MPASJEDI_ROOT:-$HOME/intel303}"
JEDI_INSTALL="${JEDI_INSTALL:-$MPASJEDI_ROOT/mpas-install}"
JEDI_CODE="${JEDI_CODE:-$MPASJEDI_ROOT/code}"
JEDI_BUILD="${JEDI_BUILD:-$MPASJEDI_ROOT/build}"
JEDI_EXE="${JEDI_EXE:-$JEDI_INSTALL/bin/mpasjedi_error_covariance_toolbox.x}"

GRID="${GRID:-4096002}"
XNN="${XNN:-x1}"
MPAS_RESOLUTION="${MPAS_RESOLUTION:-12}"

MESH_DIR="${MESH_DIR:-$MODEL_ROOT/src/mpas/meshes/$MPAS_RESOLUTION}"
INVARIANT="${INVARIANT:-$MESH_DIR/${XNN}.${GRID}.invariant.nc}"
GRAPH_PREFIX="${GRAPH_PREFIX:-$MESH_DIR/${XNN}.${GRID}.graph.info.part.}"
GRAPH_FILE="${GRAPH_PREFIX}${SLURM_NTASKS}"

NAMELIST_DIR="${NAMELIST_DIR:-$JEDI_CODE/mpas-jedi/test/testinput/namelists}"
PHYSICS_DIR="${PHYSICS_DIR:-$JEDI_BUILD/mpas-jedi/test}"

SAMPLES_DIR="${SAMPLES_DIR:-$HOME/jedi/mpas_only/4.0.0/samples}"
SAMPLE_GLOB="${SAMPLE_GLOB:-PTB_f48mf24_*.nc}"

BG_FILE="${BG_FILE:-/scratch/lus/arw/jedi/Bflow_preprocessing/output/2026051300/FULL_f48.nc}"
REF_DATE_TIME="${REF_DATE_TIME:-2026-05-13_00}"
DATE_STRING="${REF_DATE_TIME/_/T}:00:00Z"

ENSGEN_ROOT="${ENSGEN_ROOT:-$ROOT/ENSGEN_B}"
WORK_DIR="${WORK_DIR:-$ENSGEN_ROOT/work}"
NICAS_DIR="${NICAS_DIR:-$ENSGEN_ROOT/NICAS}"
STDDEV_DIR="${STDDEV_DIR:-$ENSGEN_ROOT/STDDEV}"
DIAG_DIR="${DIAG_DIR:-$ENSGEN_ROOT/DIAGNOSTICS}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"

BUMP_PREFIX="${BUMP_PREFIX:-mpas_ensgen_bump}"

COMPUTATION_GRID_SIZE="${COMPUTATION_GRID_SIZE:-4096}"
DIAGNOSTIC_GRID_SIZE="${DIAGNOSTIC_GRID_SIZE:-300}"
DISTANCE_CLASSES="${DISTANCE_CLASSES:-20}"
DISTANCE_CLASS_WIDTH="${DISTANCE_CLASS_WIDTH:-500000.0}"
REDUCED_LEVELS="${REDUCED_LEVELS:-56}"
AVERAGING_LENGTH_SCALE="${AVERAGING_LENGTH_SCALE:-1000000.0}"
NICAS_RESOLUTION="${NICAS_RESOLUTION:-8.0}"
NICAS_MAX_HORIZONTAL_GRID_SIZE="${NICAS_MAX_HORIZONTAL_GRID_SIZE:-60000}"
INITIAL_LENGTH_SCALE="${INITIAL_LENGTH_SCALE:-3000000.0}"
HORIZONTAL_FILTERING_LENGTH_SCALE="${HORIZONTAL_FILTERING_LENGTH_SCALE:-3000000.0}"

VARS=(temperature spechum uReconstructZonal uReconstructMeridional surface_pressure)

source "$MODEL_ROOT/slurm/modelenv.sh" >/dev/null 2>&1
source "$HOME/spack-stack-oper/switch_to_oper.sh" >/dev/null 2>&1

export PATH="$JEDI_INSTALL/bin:$PATH"
export LD_LIBRARY_PATH="$JEDI_INSTALL/lib64:$JEDI_INSTALL/lib:${LD_LIBRARY_PATH:-}"
export OMP_NUM_THREADS=1
export OOPS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export HDF5_USE_FILE_LOCKING=FALSE
export F_UFMTENDIAN='big:101-200'
export MPICH_COLL_OPT_OFF=MPI_Scatterv
export MPICH_COLL_SYNC=MPI_Gather
export MPICH_RANK_REORDER_METHOD=0

ulimit -s unlimited
ulimit -c 0
ulimit -v unlimited
ulimit -d unlimited
ulimit -m unlimited 2>/dev/null || true

mkdir -p "$LOG_DIR"

[ -x "$JEDI_EXE" ] || fail "missing executable: $JEDI_EXE"
require_file "$INVARIANT"
require_file "$GRAPH_FILE"
require_file "$BG_FILE"
require_dir "$NAMELIST_DIR"
require_dir "$SAMPLES_DIR"

mapfile -t SAMPLE_FILES < <(
    find -L "$SAMPLES_DIR" -maxdepth 1 -type f -name "$SAMPLE_GLOB" | sort
)

NSAMPLES="${#SAMPLE_FILES[@]}"
[ "$NSAMPLES" -ge 5 ] || fail "at least five samples are required; found $NSAMPLES"

for sample in "${SAMPLE_FILES[@]}"; do
    require_file "$sample"
    for var in "${VARS[@]}"; do
        var_exists "$sample" "$var" || fail "$sample does not contain $var"
    done
done

REF_NCELLS="$(ncdump -h "${SAMPLE_FILES[0]}" | sed -n 's/^[[:space:]]*nCells = \([0-9][0-9]*\) ;/\1/p' | head -1)"
REF_NLEVELS="$(ncdump -h "${SAMPLE_FILES[0]}" | sed -n 's/^[[:space:]]*nVertLevels = \([0-9][0-9]*\) ;/\1/p' | head -1)"

[ "$REF_NCELLS" = "$GRID" ] || fail "sample nCells=$REF_NCELLS does not match GRID=$GRID"
[ "$REF_NLEVELS" = "56" ] || fail "sample nVertLevels=$REF_NLEVELS; expected 56"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$NICAS_DIR" "$STDDEV_DIR" "$DIAG_DIR"
cd "$WORK_DIR"

ln -sfn "$INVARIANT" "${XNN}.${GRID}.invariant.nc"
ln -sfn "$GRAPH_FILE" .
ln -sfn "$BG_FILE" background.nc
ln -sfn "$BG_FILE" "templateFields.${GRID}.nc"
ln -sfn "$BG_FILE" control.nc
ln -sfn "$BG_FILE" ensemble.nc
ln -sfn "$BG_FILE" analysis.nc
ln -sfn "$BG_FILE" output.nc

ln -sfn "$NAMELIST_DIR/geovars.yaml" geovars.yaml
ln -sfn "$NAMELIST_DIR/keptvars.yaml" keptvars.yaml
ln -sfn "$JEDI_CODE/mpas-jedi/test/testinput/obsop_name_map.yaml" obsop_name_map.yaml

for stream in analysis background; do
    ln -sfn "$NAMELIST_DIR/stream_list.atmosphere.$stream" "stream_list.atmosphere.$stream"
done

cat > stream_list.atmosphere.control <<'EOF_CONTROL'
temperature
spechum
uReconstructZonal
uReconstructMeridional
surface_pressure
EOF_CONTROL

cp -p stream_list.atmosphere.control stream_list.atmosphere.ensemble

if [ -d "$PHYSICS_DIR" ]; then
    for src in "$PHYSICS_DIR"/*; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"
        case "$name" in
            *.TBL|*.DBL|RRTMG_*|RRTM_*|CAM_*|VERSION|COMPATIBILITY)
                ln -sfn "$src" "$name"
                ;;
        esac
    done
fi

for resource in geovars.yaml keptvars.yaml obsop_name_map.yaml     stream_list.atmosphere.control stream_list.atmosphere.ensemble     GENPARM.TBL LANDUSE.TBL SOILPARM.TBL VEGPARM.TBL RRTMG_LW_DATA RRTMG_SW_DATA
do
    require_file "$resource"
done

cat > streams.atmosphere <<EOF_STREAMS
<streams>
<immutable_stream name="invariant" type="input" precision="single"
                  filename_template="${XNN}.${GRID}.invariant.nc"
                  io_type="pnetcdf,cdf5" input_interval="initial_only" />
<immutable_stream name="input" type="input" precision="single"
                  filename_template="templateFields.${GRID}.nc"
                  io_type="pnetcdf,cdf5" input_interval="initial_only" />
<immutable_stream name="da_state" type="output" precision="single"
                  io_type="pnetcdf,cdf5"
                  filename_template="mpasout.\$Y-\$M-\$D_\$h.\$m.\$s.nc"
                  packages="jedi_da" output_interval="none"
                  clobber_mode="overwrite" />
<stream name="background" type="input" precision="single"
        io_type="pnetcdf,cdf5" filename_template="background.nc"
        input_interval="initial_only">
  <file name="stream_list.atmosphere.background"/>
</stream>
<stream name="ensemble" type="input" precision="single"
        io_type="pnetcdf,cdf5" filename_template="ensemble.nc"
        input_interval="initial_only">
  <file name="stream_list.atmosphere.ensemble"/>
</stream>
<stream name="analysis" type="output" precision="single"
        io_type="pnetcdf,cdf5" filename_template="analysis.nc"
        output_interval="none" clobber_mode="overwrite">
  <file name="stream_list.atmosphere.analysis"/>
</stream>
<stream name="control" type="input;output" precision="single"
        io_type="pnetcdf,cdf5" filename_template="control.nc"
        input_interval="initial_only" output_interval="initial_only"
        clobber_mode="overwrite">
  <file name="stream_list.atmosphere.control"/>
</stream>
<stream name="output" type="none" filename_template="output.nc"
        output_interval="0_01:00:00" />
<stream name="diagnostics" type="none" filename_template="diagnostics.nc"
        output_interval="0_01:00:00" />
</streams>
EOF_STREAMS

cat > namelist.atmosphere <<EOF_NML
&nhyd_model
 config_time_integration_order = 2
 config_dt = 72.0
 config_start_time = '${REF_DATE_TIME}:00:00'
 config_run_duration = '0_00:00:00'
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

MEMBERS_YAML=""
for sample in "${SAMPLE_FILES[@]}"; do
    MEMBERS_YAML+="    - filename: ${sample}"$'\n'
    MEMBERS_YAML+="      date: *validDate"$'\n'
    MEMBERS_YAML+="      state variables: *vars"$'\n'
    MEMBERS_YAML+="      stream name: ensemble"$'\n'
done

cat > run_bumpcov.yaml <<EOF_YAML
geometry:
  nml_file: "./namelist.atmosphere"
  streams_file: "./streams.atmosphere"
  deallocate non-da fields: true
  bump vunit: "avgheight"

background:
  state variables: &vars
  - temperature
  - spechum
  - uReconstructZonal
  - uReconstructMeridional
  - surface_pressure
  filename: "./background.nc"
  date: &validDate '${DATE_STRING}'
  stream name: control

background error:
  covariance model: SABER
  ensemble:
    members:
${MEMBERS_YAML}
  saber central block:
    saber block name: BUMP_NICAS
    active variables: *vars
    calibration:
      io:
        data directory: .
        files prefix: ${BUMP_PREFIX}
      drivers:
        compute covariance: true
        compute correlation: true
        multivariate strategy: univariate
        compute variance: true
        compute moments: true
        compute nicas: true
        write local nicas: true
        write global nicas: true
        write nicas grids: true
        internal dirac test: true
      sampling:
        computation grid size: ${COMPUTATION_GRID_SIZE}
        diagnostic grid size: ${DIAGNOSTIC_GRID_SIZE}
        distance classes: ${DISTANCE_CLASSES}
        distance class width: ${DISTANCE_CLASS_WIDTH}
        reduced levels: ${REDUCED_LEVELS}
        local diagnostic: true
        averaging length-scale: ${AVERAGING_LENGTH_SCALE}
        interpolation type: c0
      diagnostics:
        target ensemble size: ${NSAMPLES}
      variance:
        objective filtering: true
        filtering iterations: 1
        initial length-scale:
        - variables: [temperature, spechum, uReconstructZonal,
                      uReconstructMeridional, surface_pressure]
          value: ${INITIAL_LENGTH_SCALE}
        smoother max horizontal grid size: 15000
        smoother min effective resolution: 2.5
      fit:
        horizontal filtering length-scale: ${HORIZONTAL_FILTERING_LENGTH_SCALE}
      nicas:
        resolution: ${NICAS_RESOLUTION}
        max horizontal grid size: ${NICAS_MAX_HORIZONTAL_GRID_SIZE}
        min effective resolution: 2.5
        interpolation type:
        - groups: [temperature, spechum, uReconstructZonal,
                   uReconstructMeridional, surface_pressure]
          type: c0
      grids:
      - model:
          variables: [temperature, spechum, uReconstructZonal,
                      uReconstructMeridional]
          nearest 3d level: bottom
      - model:
          variables: [surface_pressure]
          nearest 3d level: bottom
      dirac:
      - longitude: 54.0
        latitude: 24.0
        level: 25
        variable: temperature
      output model files:
      - parameter: stddev
        file:
          filename: ./mpas.stddev.nc
          date: *validDate
          stream name: control
      - parameter: cor_rh
        file:
          filename: ./mpas.cor_rh.nc
          date: *validDate
          stream name: control
      - parameter: cor_rv
        file:
          filename: ./mpas.cor_rv.nc
          date: *validDate
          stream name: control
EOF_YAML

RENDERED_MEMBERS="$(grep -c '^[[:space:]]*-[[:space:]]filename: .*PTB_f48mf24_' run_bumpcov.yaml)"
[ "$RENDERED_MEMBERS" -eq "$NSAMPLES" ] || fail "rendered $RENDERED_MEMBERS members; expected $NSAMPLES"

srun --label --cpu-bind=cores -n "$SLURM_NTASKS"     --cpus-per-task="$SLURM_CPUS_PER_TASK"     "$JEDI_EXE" ./run_bumpcov.yaml ./run_bumpcov.runlog

require_file "${BUMP_PREFIX}_nicas.nc"
require_file mpas.stddev.nc
require_file mpas.cor_rh.nc
require_file mpas.cor_rv.nc

mapfile -t LOCAL_NICAS < <(find . -maxdepth 1 -type f -name "${BUMP_PREFIX}_nicas_local_*.nc" | sort)
mapfile -t LOCAL_GRIDS < <(find . -maxdepth 1 -type f -name "${BUMP_PREFIX}_nicas_grids_local_*.nc" | sort)

[ "${#LOCAL_NICAS[@]}" -eq "$SLURM_NTASKS" ] || fail "expected $SLURM_NTASKS local NICAS files; found ${#LOCAL_NICAS[@]}"
[ "${#LOCAL_GRIDS[@]}" -eq "$SLURM_NTASKS" ] || fail "expected $SLURM_NTASKS local grid files; found ${#LOCAL_GRIDS[@]}"

for var in "${VARS[@]}"; do
    h5ls -r "${BUMP_PREFIX}_nicas.nc" 2>/dev/null |
        grep -q "^/${var}[[:space:]]*Group" ||
        fail "global NICAS file is missing group $var"
done

rm -rf "$NICAS_DIR"
mkdir -p "$NICAS_DIR"
cp -p "${BUMP_PREFIX}_nicas.nc" "$NICAS_DIR/"
cp -p "${BUMP_PREFIX}_nicas_local_"*.nc "$NICAS_DIR/"
cp -p "${BUMP_PREFIX}_nicas_grids_local_"*.nc "$NICAS_DIR/"

rm -rf "$STDDEV_DIR"
mkdir -p "$STDDEV_DIR"
cp -p mpas.stddev.nc "$STDDEV_DIR/"

rm -rf "$DIAG_DIR"
mkdir -p "$DIAG_DIR"
cp -p mpas.cor_rh.nc mpas.cor_rv.nc run_bumpcov.yaml run_bumpcov.runlog "$DIAG_DIR/"

log "DONE: analysis-space ensemble-generation B created"
log "NICAS: $NICAS_DIR"
log "StdDev: $STDDEV_DIR/mpas.stddev.nc"
log "Prefix: $BUMP_PREFIX"
