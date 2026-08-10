#!/bin/bash
#SBATCH --job-name=JEDI.OPER
#SBATCH --partition=dev
#SBATCH --nodelist=nid000[001-128]
#SBATCH --export=NONE
#SBATCH --time=1:50:00
#SBATCH --exclusive
#SBATCH --nodes=96
#SBATCH --ntasks=768
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=8
#SBATCH --no-requeue
#SBATCH --output=/scratch/lus/arw/model/log/jedi.oper303.out
#SBATCH --error=/scratch/lus/arw/model/log/jedi.oper303.out

set -x

#===============================================================================
# MPAS-JEDI 3.0.3 Intel variational driver for 3D-Var, 3D-FGAT,
# 4D-FGAT, hybrid 4D-FGAT with generated ensembles, and 4D-Ens-Var.
# The script prepares the run directory, renders the YAML/namelist templates,
# links/copies required files, runs mpasjedi_variational.x, and saves analysis.
#===============================================================================

#-------------------------------------------------------------------------------
# 1. Small utility functions used throughout the workflow.
#-------------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  [ -n "${RUNLOG:-}" ] && echo "$msg" >> "$RUNLOG"
}

require_file() { [ -e "$1" ] || die "missing required file: $1"; }
require_dir()  { [ -d "$1" ] || die "missing required directory: $1"; }

date_shift() {
  local dh="$1"
  local base="$2"
  local y="${base:0:4}"
  local m="${base:4:2}"
  local d="${base:6:2}"
  local h="${base:8:2}"
  if [ -n "${SMSDATE:-}" ] && command -v "$SMSDATE" >/dev/null 2>&1; then
    "$SMSDATE" "$dh" "$base"
  else
    date -u -d "${y}-${m}-${d} ${h}:00:00 ${dh} hours" +%Y%m%d%H
  fi
}

iso_from_yyyymmddhh() {
  local dt="$1"
  printf "%s-%s-%sT%s:00:00Z" "${dt:0:4}" "${dt:4:2}" "${dt:6:2}" "${dt:8:2}"
}

link_file() {
  local src="$1" dst="$2"
  require_file "$src"
  ln -sf "$src" "$dst"
  require_file "$dst"
}

link_dir() {
  local src="$1" dst="$2"
  require_dir "$src"
  ln -sfn "$src" "$dst"
  require_dir "$dst"
}

remove_yaml_block() {
  local tag="$1" file="$2"
  perl -0pi -e "s/\n?#<${tag}>.*?#<\\/${tag}>\\n?/\n/s" "$file"
}

validate_obs_template_markers() {
  local file="$1"
  python3 - "$file" <<'PY'
from pathlib import Path
from collections import Counter
import re, sys
s=Path(sys.argv[1]).read_text()
o=re.findall(r'#<((?:OBS|MODEL)_[A-Z0-9_]+)>',s)
c=re.findall(r'#</((?:OBS|MODEL)_[A-Z0-9_]+)>',s)
if Counter(o)!=Counter(c):
    print("ERROR: malformed YAML markers",file=sys.stderr); sys.exit(1)
for tag in sorted(set(o)):
    if o.count(tag)!=1:
        print(f"ERROR: marker {tag} count={o.count(tag)}",file=sys.stderr); sys.exit(1)
    if tag.startswith("OBS_"):
        m=re.search(rf'#<{tag}>(.*?)#</{tag}>',s,re.S)
        n=len(re.findall(r'^\s*-\s+obs space:\s*$',m.group(1),re.M)) if m else 0
        if n!=1:
            print(f"ERROR: {tag} contains {n} obs spaces",file=sys.stderr); sys.exit(1)
PY
}

# Effective activation state after applying switches and missing-file policy.
# Values are set by enable_or_remove_obs() and by the surface-observation branch.
declare -A OBS_ACTIVE=()

count_final_observer() {
  local obs_name="$1" file="${2:-jedi.yaml}"
  python3 - "$file" "$obs_name" <<'PYOBSCOUNT'
from pathlib import Path
import re, sys

lines = Path(sys.argv[1]).read_text().splitlines()
target = sys.argv[2]
count = 0

for i, line in enumerate(lines):
    m = re.match(r'^(\s*)-\s+obs space:\s*$', line)
    if not m:
        continue
    item_indent = len(m.group(1))
    for nxt in lines[i + 1:]:
        # Stop at the next observer list item at the same indentation.
        nitem = re.match(r'^(\s*)-\s+obs space:\s*$', nxt)
        if nitem and len(nitem.group(1)) == item_indent:
            break
        nname = re.match(r'^(\s*)name:\s*(.*?)\s*$', nxt)
        if nname and len(nname.group(1)) > item_indent:
            if nname.group(2) == target:
                count += 1
            break
print(count)
PYOBSCOUNT
}

assert_obs_effective_result() {
  local tag="$1" obs_name="$2" expected_count="${3:-1}" file="${4:-jedi.yaml}"
  local active="${OBS_ACTIVE[$tag]:-0}" count
  count="$(count_final_observer "$obs_name" "$file")"

  if [ "$active" = "1" ]; then
    [ "$count" -eq "$expected_count" ] || \
      die "active observer $tag/$obs_name occurs $count times in $file; expected $expected_count"
  else
    [ "$count" -eq 0 ] || \
      die "inactive observer $tag/$obs_name still occurs $count times in $file"
  fi
}

validate_final_observation_inputs() {
  local file="${1:-jedi.yaml}" obsfile
  while IFS= read -r obsfile; do
    [ -n "$obsfile" ] || continue
    [ -r "$obsfile" ] || die "final YAML references unreadable observation input: $obsfile"
    [ -s "$obsfile" ] || die "final YAML references empty observation input: $obsfile"
  done < <(python3 - "$file" <<'PYOBSFILES'
from pathlib import Path
import re, sys

lines = Path(sys.argv[1]).read_text().splitlines()
in_obs_space = False
in_obsdatain = False
obs_space_indent = -1
obsdatain_indent = -1

for line in lines:
    stripped = line.strip()
    indent = len(line) - len(line.lstrip())

    mspace = re.match(r'^(\s*)-\s+obs space:\s*$', line)
    if mspace:
        in_obs_space = True
        in_obsdatain = False
        obs_space_indent = len(mspace.group(1))
        continue

    if in_obs_space and stripped and indent <= obs_space_indent and not stripped.startswith('#'):
        in_obs_space = False
        in_obsdatain = False

    if not in_obs_space:
        continue

    if re.match(r'^\s*obsdatain:\s*$', line):
        in_obsdatain = True
        obsdatain_indent = indent
        continue

    if in_obsdatain and stripped and indent <= obsdatain_indent:
        in_obsdatain = False

    if in_obsdatain:
        m = re.match(r'^\s*obsfile:\s*["\']?(.*?)["\']?\s*$', line)
        if m:
            print(m.group(1))
PYOBSFILES
  )
}

log_final_observers() {
  local file="${1:-jedi.yaml}"
  python3 - "$file" <<'PYOBSLIST'
from pathlib import Path
import re, sys

lines = Path(sys.argv[1]).read_text().splitlines()
for i, line in enumerate(lines):
    m = re.match(r'^(\s*)-\s+obs space:\s*$', line)
    if not m:
        continue
    item_indent = len(m.group(1))
    for nxt in lines[i + 1:]:
        nitem = re.match(r'^(\s*)-\s+obs space:\s*$', nxt)
        if nitem and len(nitem.group(1)) == item_indent:
            break
        nname = re.match(r'^(\s*)name:\s*(.*?)\s*$', nxt)
        if nname and len(nname.group(1)) > item_indent:
            print(nname.group(2))
            break
PYOBSLIST
}

enable_or_remove_obs() {
  local tag="$1" enabled="$2" src_kind="$3" local_name="$4"
  local src="$JEDI_ROOT/${src_kind}_${ANL_TAG_H5}.h5"

  if [ "$enabled" != "1" ]; then
    OBS_ACTIVE["$tag"]=0
    remove_yaml_block "$tag" jedi.yaml
    log "OBS $tag disabled: YAML block removed"
    return 0
  fi

  if [ ! -s "$src" ]; then
    if [ "$JEDI_OBS_MISSING_POLICY" = "skip" ]; then
      OBS_ACTIVE["$tag"]=0
      remove_yaml_block "$tag" jedi.yaml
      log "OBS $tag enabled but missing; skipped: $src"
      return 0
    fi
    die "OBS $tag enabled but file is missing: $src"
  fi

  ln -sf "$src" "$local_name"
  require_file "$local_name"
  OBS_ACTIVE["$tag"]=1
  log "OBS $tag enabled: $local_name -> $src"
}

link_physics_files() {
  local src_dir="$1"; shift
  local f
  [ -d "$src_dir" ] || { log "WARNING: physics table directory not found: $src_dir"; return 0; }
  for f in "$@"; do
    [ -f "$src_dir/$f" ] && ln -sf "$src_dir/$f" .
  done
}

safe_clean_workdir() {
  local dir="$1"
  mkdir -p "$dir"
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

#-------------------------------------------------------------------------------
# 2. Load the operational environment and Intel MPAS-JEDI 3.0.3 runtime.
#-------------------------------------------------------------------------------

. /scratch/lus/arw/model/slurm/modelenv.sh >/dev/null 2>&1

#-------------------------------------------------------------------------------
# 3. Validate mandatory operational inputs.
#-------------------------------------------------------------------------------
echo $START_DATE

: "${START_DATE:?START_DATE must be YYYYMMDDHH}"
: "${MPAS_RESOLUTION:?MPAS_RESOLUTION not set}"

#-------------------------------------------------------------------------------
# 4. Define cycle time, analysis time, DA window, and variational mode once.
#-------------------------------------------------------------------------------

RUN_DATE="$START_DATE"
CYCLE_RUN="${RUN_DATE:8:2}"
ANALYSIS_DATE="$(date_shift -12 "$RUN_DATE")"

YYYY="${ANALYSIS_DATE:0:4}"
MM="${ANALYSIS_DATE:4:2}"
DD="${ANALYSIS_DATE:6:2}"
HH="${ANALYSIS_DATE:8:2}"

ANL_TAG_H5="$ANALYSIS_DATE"
ANL_ISO="$(iso_from_yyyymmddhh "$ANALYSIS_DATE")"

JEDI_VAR_MODE=4D-FGAT-ENS
JEDI_NINNER=50
JEDI_GRADIENT_NORM_REDUCTION=1.0e-3
JEDI_LINEAR_MODEL_NAME=Identity
WIN_LEN=PT6H
FGAT_TSTEP=PT30M
WIN_BEG_DATE="$(date_shift -3 "$ANALYSIS_DATE")"
WIN_BEG_ISO="$(iso_from_yyyymmddhh "$WIN_BEG_DATE")"
WIN_END_DATE="$(date_shift "+3" "$ANALYSIS_DATE")"
WIN_END_ISO="$(iso_from_yyyymmddhh "$WIN_END_DATE")"

USE_FGAT_ENSEMBLE_B=0
USE_4D_ENSEMBLE_TRAJECTORIES=0

cd "$HOME/intel303" || die "cannot enter $HOME/intel303"
source "$HOME/spack-stack-oper/switch_to_oper.sh" >/dev/null 2>&1

# The batch job starts with --export=NONE to avoid inheriting the
# submission-shell environment.  From this point onward the controlled
# Intel/Spack environment created above must be inherited by srun steps.
export SLURM_EXPORT_ENV=ALL

# Fixed operational roots used by this script.
MODEL_ROOT=/scratch/lus/arw/model
DAY_ROOT=/scratch/lus/tmp/arw/day
ASSIM_ROOT="$DAY_ROOT/assim"

# Keep the Intel 3.0.3 installation first without changing GNU-tested YAML logic.
export LD_LIBRARY_PATH="$HOME/intel303/mpas-install/lib64:$HOME/intel303/mpas-install/lib:${LD_LIBRARY_PATH}"
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

case "$JEDI_VAR_MODE" in
  3DVAR|3D-VAR|3D-Var)
    COST_TYPE="3D-Var"
    USE_MODEL_BLOCK=0
    USE_LINEAR_MODEL=0
    OUTER_LOOP_COUNT=1
    BG_DATE="$ANALYSIS_DATE"
    MPAS_NML_DATE="$ANALYSIS_DATE"
    ;;
  FGAT|3D-FGAT|3D_FGAT)
    COST_TYPE="3D-FGAT"
    USE_MODEL_BLOCK=1
    USE_LINEAR_MODEL=0
    OUTER_LOOP_COUNT=1
    BG_DATE="$WIN_BEG_DATE"
    MPAS_NML_DATE="$WIN_BEG_DATE"
    ;;
  4DVAR|4D-VAR|4D-Var|4D_FGAT|4D-FGAT)
    COST_TYPE="4D-Var"
    USE_MODEL_BLOCK=1
    USE_LINEAR_MODEL=1
    OUTER_LOOP_COUNT=2
    BG_DATE="$WIN_BEG_DATE"
    MPAS_NML_DATE="$WIN_BEG_DATE"
    ;;
  4D-FGAT-ENS|4D_FGAT_ENS|4DFGATENS|4D-FGAT-HYBRID|4DFGATHYBRID)
    # Deterministic 4D-FGAT/4D-Var with a hybrid background-error covariance.
    # MPAS integrates the deterministic trajectory through the 6-hour window.
    # The static SABER component is combined with an ensemble component whose
    # members each contain states at T-3h, T, and T+3h. The ensemble trajectories
    # appear only under "background error"; they never replace the deterministic
    # 4D-Var background or nonlinear MPAS trajectory.
    COST_TYPE="4D-Var"
    USE_MODEL_BLOCK=1
    USE_LINEAR_MODEL=1
    USE_FGAT_ENSEMBLE_B=1
    OUTER_LOOP_COUNT=2
    BG_DATE="$WIN_BEG_DATE"
    MPAS_NML_DATE="$WIN_BEG_DATE"
    ;;
  4DENSVAR|4D-ENS-VAR|4D_EnsVar|4D-EnVar|4DENS-VAR)
    # Pure 4D-EnVar/4D-Ens-Var:
    # No MPAS trajectory is integrated inside the variational run.
    # The 4D information comes from precomputed ensemble states at T-3h, T, T+3h.
    COST_TYPE="4D-Ens-Var"
    USE_MODEL_BLOCK=0
    USE_LINEAR_MODEL=0
    USE_4D_ENSEMBLE_TRAJECTORIES=1
    OUTER_LOOP_COUNT=2
    BG_DATE="$WIN_BEG_DATE"
    MPAS_NML_DATE="$WIN_BEG_DATE"
    ;;
  *)
    die "Unsupported JEDI_VAR_MODE=$JEDI_VAR_MODE. Use 3DVAR, 3D-FGAT, 4D-FGAT, 4D-FGAT-ENS, or 4DENSVAR"
    ;;
esac

BG_ISO="$(iso_from_yyyymmddhh "$BG_DATE")"

if [ "$COST_TYPE" = "3D-FGAT" ]; then
  STDDEV_ISO="$ANL_ISO"
else
  STDDEV_ISO="$BG_ISO"
fi

case "$WIN_LEN" in
  PT1H)  MPAS_FORECAST_LENGTH="0_01:00:00" ;;
  PT3H)  MPAS_FORECAST_LENGTH="0_03:00:00" ;;
  PT6H)  MPAS_FORECAST_LENGTH="0_06:00:00" ;;
  PT12H) MPAS_FORECAST_LENGTH="0_12:00:00" ;;
  *) die "Unsupported WIN_LEN=$WIN_LEN for MPAS_FORECAST_LENGTH mapping" ;;
esac

BG_YYYY="${BG_DATE:0:4}"
BG_MM="${BG_DATE:4:2}"
BG_DD="${BG_DATE:6:2}"
BG_HH="${BG_DATE:8:2}"

MPAS_NML_YYYY="${MPAS_NML_DATE:0:4}"
MPAS_NML_MM="${MPAS_NML_DATE:4:2}"
MPAS_NML_DD="${MPAS_NML_DATE:6:2}"
MPAS_NML_HH="${MPAS_NML_DATE:8:2}"

#-------------------------------------------------------------------------------
# 5. Set MPAS mesh metadata from the selected operational resolution.
#-------------------------------------------------------------------------------

case "$MPAS_RESOLUTION" in
  10)    XNN=x1;  NUM=5898242; DT=60.0; DX=10000.0 ;;
  12)    XNN=x1;  NUM=4096002; DT=72.0; DX=12000.0 ;;
  15)    XNN=x1;  NUM=2621442; DT=90.0; DX=15000.0 ;;
  15_3)  XNN=x5;  NUM=6488066; DT=20.0; DX=3000.0  ;;
  30_5)  XNN=x6;  NUM=2819097; DT=36.0; DX=5000.0  ;;
  15_5)  XNN=x3;  NUM=4763609; DT=36.0; DX=5000.0  ;;
  60_10) XNN=x6;  NUM=999426 ; DT=60.0; DX=10000.0 ;;
  60_3)  XNN=x20; NUM=835586 ; DT=20.0; DX=3000.0  ;;
  46_12) XNN=x4;  NUM=655362 ; DT=72.0; DX=12000.0 ;;
  60_15) XNN=x4;  NUM=535554 ; DT=90.0; DX=15000.0 ;;
  *) die "unsupported MPAS_RESOLUTION=$MPAS_RESOLUTION" ;;
esac

# Preserve the native/source mesh metadata before selecting the lower-resolution
# JEDI geometry. These values are used only by the mesh-remapping stage.
SOURCE_MPAS_RESOLUTION="$MPAS_RESOLUTION"
SOURCE_XNN="$XNN"
SOURCE_NUM="$NUM"

#-------------------------------------------------------------------------------
# 6. Define directory layout, executables, static B files, CRTM files, and outputs.
#-------------------------------------------------------------------------------

JEDI_ROOT="$DAY_ROOT/jedi/r${CYCLE_RUN}"
LOGDIR="$MODEL_ROOT/log"
RUNLOG="$LOGDIR/jedi.var.${RUN_DATE}.log"
# One common runtime directory for both ensemble generation and variational DA.
# All rendered YAML, namelist, stream, diagnostic, and log-support files remain
# here for operational inspection. Ensemble NetCDF outputs still go to
# ENSEMBLE_ROOT under $DAY_ROOT/ens.
WORKDIR="$HOME/intel303/run"

mkdir -p "$JEDI_ROOT" "$LOGDIR" "$WORKDIR" "$ASSIM_ROOT"
: > "$RUNLOG"

MPAS_ONLY_ROOT="$HOME/jedi/mpas_only/3.0.3"
JEDI_NAME_DIR="$MODEL_ROOT/name/jedi"
MPASJEDI_BUNDLE_ROOT="$HOME/intel303"
JEDI_RESOURCE_DIR="$MPASJEDI_BUNDLE_ROOT/code/mpas-jedi/test/testinput/namelists"
JEDI_OBSOP_NAME_MAP="$MPASJEDI_BUNDLE_ROOT/code/mpas-jedi/test/testinput/obsop_name_map.yaml"
TEMPLATE_YAML="$JEDI_NAME_DIR/jedi.303.yaml"

MPASJEDI_INSTALL="$MPASJEDI_BUNDLE_ROOT/mpas-install"
MPASJEDI_EXE="$MPASJEDI_INSTALL/bin/mpasjedi_variational.x"
MPASJEDI_GEN_ENS_EXE="$MPASJEDI_INSTALL/bin/mpasjedi_gen_ens_pert_B.x"
# Source template maintained with the operational templates.
PERT_TEMPLATE_SOURCE="$JEDI_NAME_DIR/pert.303.yaml"

# Runtime copy kept beside gen_ens_pert_B.yaml and jedi.yaml.
PERT_TEMPLATE_YAML="$WORKDIR/pert.303.yaml"

#-------------------------------------------------------------------------------
# MPAS-JEDI runtime library path is prepared by
# $HOME/spack-stack-oper/switch_to_oper.sh and the intel303 install prefix.
# Do not re-add /scratch/lus/dev here; that was the source of old ABI pollution.

#-------------------------------------------------------------------------------

# STDDEV_FILE is assigned after the low-resolution B root is selected below.

# Native high-resolution restart inputs. They are never modified.
SOURCE_BG_FILE="$ASSIM_ROOT/restart.${BG_YYYY}-${BG_MM}-${BG_DD}_${BG_HH}:00:00.nc"
SOURCE_AN_GUESS_FILE="$ASSIM_ROOT/restart.${YYYY}-${MM}-${DD}_${HH}:00:00.nc"

#-------------------------------------------------------------------------------
# Low-resolution ensemble geometry.
#
# This is the ONLY resolution selector for the downscaled ensemble workflow.
# Set it here to either 24 or 30.  It is intentionally not inherited from the
# submission environment.
#-------------------------------------------------------------------------------

ENSEMBLE_LOWRESOLUTION=24

JEDI_REMAP_ENABLE=1
JEDI_REMAP_EXE="$HOME/mpas_mesh_remap_fast/mpas_mesh_remap"
JEDI_REMAP_NEIGHBORS=4
JEDI_REMAP_POWER=2.0
JEDI_REMAP_THREADS="${SLURM_CPUS_PER_TASK:-8}"
JEDI_REMAP_ROOT="$ASSIM_ROOT/remapped/${ENSEMBLE_LOWRESOLUTION}km"

case "$ENSEMBLE_LOWRESOLUTION" in
  24)
    TARGET_XNN=x1
    TARGET_NUM=1024002
    TARGET_DT=144.0
    TARGET_DX=24000.0
    ENSEMBLE_MODEL_TSTEP=PT2M24S
    ;;
  30)
    TARGET_XNN=x1
    TARGET_NUM=655362
    TARGET_DT=180.0
    TARGET_DX=30000.0
    ENSEMBLE_MODEL_TSTEP=PT3M
    ;;
  *)
    die "unsupported ENSEMBLE_LOWRESOLUTION=$ENSEMBLE_LOWRESOLUTION; use 24 or 30"
    ;;
esac

LOWRES_B_ROOT="$MPAS_ONLY_ROOT/${ENSEMBLE_LOWRESOLUTION}km"
STDDEV_FILE="$LOWRES_B_ROOT/HDIAGS/merge/mpas.stddev.nc"

SOURCE_INVARIANT_FILE="$MODEL_ROOT/src/mpas/meshes/$SOURCE_MPAS_RESOLUTION/${SOURCE_XNN}.${SOURCE_NUM}.invariant.nc"
TARGET_INVARIANT_FILE="$MODEL_ROOT/src/mpas/meshes/$ENSEMBLE_LOWRESOLUTION/${TARGET_XNN}.${TARGET_NUM}.invariant.nc"

LOWRES_BG_FILE="$JEDI_REMAP_ROOT/restart.${BG_YYYY}-${BG_MM}-${BG_DD}_${BG_HH}:00:00.nc"
LOWRES_AN_GUESS_FILE="$JEDI_REMAP_ROOT/restart.${YYYY}-${MM}-${DD}_${HH}:00:00.nc"

if [ "$JEDI_REMAP_ENABLE" = "1" ]; then
  MPAS_RESOLUTION="$ENSEMBLE_LOWRESOLUTION"
  XNN="$TARGET_XNN"
  NUM="$TARGET_NUM"
  DT="$TARGET_DT"
  DX="$TARGET_DX"
  BG_FILE="$LOWRES_BG_FILE"
  AN_GUESS_FILE="$LOWRES_AN_GUESS_FILE"
else
  BG_FILE="$SOURCE_BG_FILE"
  AN_GUESS_FILE="$SOURCE_AN_GUESS_FILE"
fi

# Native middle-window restart used as the complete forecast-state template.

# JEDI diagnostic analysis at the exact middle of the assimilation window.
# JEDI writes this file through the analysis output stream; it is not linked here.
JEDI_MID_ANALYSIS_FILE="$ASSIM_ROOT/analysis.${YYYY}-${MM}-${DD}_${HH}.00.00.nc"

# Final complete analysis used to initialize the subsequent forecast.
AN_ANALYSIS_FILE="$ASSIM_ROOT/jedi_analysis.${YYYY}-${MM}-${DD}_${HH}.00.00.nc"

# Parallel copy and field-merge controls.
DCP_NODES=4
DCP_TASKS_PER_NODE=8
DCP_NTASKS="$((DCP_NODES * DCP_TASKS_PER_NODE))"
DCP_BUFSIZE=67108864          # 64 MiB
DCP_CHUNKSIZE=1073741824   # 1 GiB
DCP_PROGRESS=10
DCP_TMP_DIR="$ASSIM_ROOT/.jedi_dcp"
JEDI_ANALYSIS_VARS=pressure_p,rho,qv,qc,qr,qi,qs,qg,surface_pressure,theta,u,uReconstructZonal,uReconstructMeridional


if [ "$JEDI_REMAP_ENABLE" = "1" ]; then
  INVARIANT_FILE="$TARGET_INVARIANT_FILE"
else
  INVARIANT_FILE="$SOURCE_INVARIANT_FILE"
fi

#CRTM_FIX_ROOT="${CRTM_FIX_ROOT:-$MPASJEDI_BUNDLE_ROOT/code/test-data-release/crtm/fix_REL-3.1.2.0/fix}"
CRTM_COEFFS_SRC="$MPASJEDI_BUNDLE_ROOT/code/test-data-release/crtm/2.4.1_skylab_4.0"
UFOCOEFF_CACHE="$JEDI_NAME_DIR/UFOCoeff"

RAD_BIAS_ROOT="$MPASJEDI_BUNDLE_ROOT/code/ufo-data/testinput_tier_1"

# Persistent VarBC state. Each sensor cycles one coefficient file and one
# covariance file. Outputs are first written in WORKDIR and installed only
# after a successful variational run.
VARBC_ROOT="$ASSIM_ROOT/varbc"
VARBC_BCOEFF_DIR="$VARBC_ROOT/bcoeff"
VARBC_COV_DIR="$VARBC_ROOT/cov"
mkdir -p "$VARBC_BCOEFF_DIR" "$VARBC_COV_DIR"

configure_varbc_sensor() {
  local key="$1" sensor="$2"
  local bcoeff_store="$VARBC_BCOEFF_DIR/satbias_${sensor}.nc4"
  local cov_store="$VARBC_COV_DIR/satbias_cov_${sensor}.nc4"
  local bcoeff_out="$WORKDIR/satbias_${sensor}.${ANL_TAG_H5}.nc4"
  local cov_out="$WORKDIR/satbias_cov_${sensor}.${ANL_TAG_H5}.nc4"
  local bcoeff_input_block="" cov_prior_block="" mode="cold-start"

  if [ -s "$bcoeff_store" ] && [ -s "$cov_store" ]; then
    mode="cycle"
    bcoeff_input_block="        input file: $bcoeff_store"
    cov_prior_block=$(cat <<EOF
          prior:
            input file: $cov_store
            inflation:
              ratio: 1.1
              ratio for small dataset: 2.0
EOF
)
  elif [ -e "$bcoeff_store" ] || [ -e "$cov_store" ]; then
    log "WARNING: incomplete VarBC pair for $sensor; cold-starting both files"
  fi

  printf -v "${key}_BIAS_INPUT_BLOCK" '%s' "$bcoeff_input_block"
  printf -v "${key}_COV_PRIOR_BLOCK" '%s' "$cov_prior_block"
  printf -v "${key}_BIAS_OUT" '%s' "$bcoeff_out"
  printf -v "${key}_COV_OUT" '%s' "$cov_out"
  printf -v "${key}_BIAS_STORE" '%s' "$bcoeff_store"
  printf -v "${key}_COV_STORE" '%s' "$cov_store"
  printf -v "${key}_VARBC_MODE" '%s' "$mode"

  export "${key}_BIAS_INPUT_BLOCK" "${key}_COV_PRIOR_BLOCK"
  log "VarBC $sensor: $mode"
}

configure_varbc_sensor AMSUA_METOP_B amsua_metop-b
configure_varbc_sensor AMSUA_METOP_C amsua_metop-c
configure_varbc_sensor MHS_METOP_B mhs_metop-b
configure_varbc_sensor MHS_METOP_C mhs_metop-c
configure_varbc_sensor IASI_METOP_B iasi_metop-b

# Sensor-specific lapse-rate predictor means.
AMSUA_METOP_B_TLAPMEAN="$RAD_BIAS_ROOT/instruments/radiance/amsua_metop-b_tlapmean.txt"
AMSUA_METOP_C_TLAPMEAN="$RAD_BIAS_ROOT/instruments/radiance/amsua_metop-c_tlapmean.txt"
MHS_METOP_B_TLAPMEAN="$RAD_BIAS_ROOT/instruments/radiance/mhs_metop-b_tlapmean.txt"
MHS_METOP_C_TLAPMEAN="$RAD_BIAS_ROOT/instruments/radiance/mhs_metop-c_tlapmean.txt"
IASI_METOP_B_TLAPMEAN="$RAD_BIAS_ROOT/instruments/radiance/iasi_metop-b_tlapmean.txt"

# Optional extra sensors retained for templates that contain their blocks.
AMSUA_N18_BIAS_IN="$RAD_BIAS_ROOT/satbias_amsua_n18.2020110106.nc4"
AMSUA_N18_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_amsua_n18.${ANL_TAG_H5}.nc4"
ATMS_NPP_BIAS_IN="$RAD_BIAS_ROOT/satbias_atms_npp.nc4"
ATMS_NPP_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_atms_npp.${ANL_TAG_H5}.nc4"
ATMS_N20_BIAS_IN="$RAD_BIAS_ROOT/satbias_atms_n20.2020110106.nc4"
ATMS_N20_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_atms_n20.${ANL_TAG_H5}.nc4"
IASI_METOP_A_BIAS_IN="$RAD_BIAS_ROOT/satbias_iasi_metop-a.nc4"
IASI_METOP_A_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_iasi_metop-a.${ANL_TAG_H5}.nc4"
CRIS_FSR_NPP_BIAS_IN="$RAD_BIAS_ROOT/satbias_cris-fsr_npp.nc4"
CRIS_FSR_NPP_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_cris-fsr_npp.${ANL_TAG_H5}.nc4"
CRIS_FSR_N20_BIAS_IN="$RAD_BIAS_ROOT/satbias_cris-fsr_n20.nc4"
CRIS_FSR_N20_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_cris-fsr_n20.${ANL_TAG_H5}.nc4"
SEVIRI_M11_BIAS_IN="$RAD_BIAS_ROOT/satbias_seviri_m11.2020110106.nc4"
SEVIRI_M11_BIAS_OUT="$RAD_BIAS_ROOT/out_satbias_seviri_m11.${ANL_TAG_H5}.nc4"

JEDI_OBS_MISSING_POLICY=skip

# Ensemble options shared by two distinct modes:
#
#   JEDI_VAR_MODE=4D-FGAT-ENS
#     - MPAS generates the deterministic FGAT trajectory during variational.
#     - A hybrid B uses one generated ensemble state per member at BG_DATE.
#
#   JEDI_VAR_MODE=4DENSVAR
#     - No MPAS trajectory is integrated during variational.
#     - Three precomputed states per member are used at T-3h, T, and T+3h.
#
# Old ENVAR_* environment names remain accepted for backward compatibility.
ENSEMBLE_MEMBERS=11
ENSEMBLE_GENERATE_MEMBERS=1
ENSEMBLE_FORECAST_LENGTH="$WIN_LEN"
ENSEMBLE_OUTPUT_FREQUENCY=PT3H
# ENSEMBLE_MODEL_TSTEP is selected above from ENSEMBLE_LOWRESOLUTION.

ENSEMBLE_STATIC_WEIGHT=0.75
ENSEMBLE_FLOW_WEIGHT=0.25

# Resolution is part of the path so a 24-km ensemble can never be mistaken for
# a 30-km ensemble from the same analysis cycle.
ENSEMBLE_ROOT="$DAY_ROOT/ens/${ENSEMBLE_LOWRESOLUTION}km/r${CYCLE_RUN}/${ANALYSIS_DATE}"

# Flow-dependent localization is retained separately.  If these ensemble states
# are subsequently consumed on the low-resolution geometry, this directory must
# contain localization files generated for the same mesh.
ENSEMBLE_BUMPLOC_DATA_DIR="$LOWRES_B_ROOT/BUMPLOC"
ENSEMBLE_BUMPLOC_FILES_PREFIX=mpas_bumploc

# Static BUMP covariance/VBAL paths used by both deterministic static B and 4D-EnVar static component.
STATIC_BUMPCOV_DATA_DIR="$LOWRES_B_ROOT/NICAS/merge"
STATIC_BUMPCOV_FILES_PREFIX=mpas
STATIC_VBAL_DATA_DIR="$LOWRES_B_ROOT/VBAL"
STATIC_STDDEV_FILE="$STDDEV_FILE"

#-------------------------------------------------------------------------------
# 7. Define observation switches in one place.
#-------------------------------------------------------------------------------

#-------------------------------------------------------------------------------
# Observation spaces
#-------------------------------------------------------------------------------

JEDI_ENABLE_AIRCRAFT=1
JEDI_ENABLE_GNSSRO=1
JEDI_ENABLE_SATWIND=1
JEDI_ENABLE_SATWND=1
JEDI_ENABLE_SFC=1
JEDI_ENABLE_SONDES=1
JEDI_ENABLE_PROFILER=0
JEDI_ENABLE_ASCAT=1

#-------------------------------------------------------------------------------
# Microwave radiances
#-------------------------------------------------------------------------------

JEDI_ENABLE_AMSUA_METOP_B=1
JEDI_ENABLE_AMSUA_METOP_C=1
JEDI_ENABLE_MHS_METOP_B=1
JEDI_ENABLE_MHS_METOP_C=1

#-------------------------------------------------------------------------------
# Infrared radiances
#-------------------------------------------------------------------------------

JEDI_ENABLE_IASI_METOP_B=1
JEDI_ENABLE_IASI_METOP_C=1

#-------------------------------------------------------------------------------
# Currently disabled (no corresponding IODA files available)
#-------------------------------------------------------------------------------

JEDI_ENABLE_AMSUA_N18=1
JEDI_ENABLE_ATMS_NPP=1
JEDI_ENABLE_ATMS_N20=1
JEDI_ENABLE_IASI_METOP_A=1
JEDI_ENABLE_CRIS_FSR_NPP=1
JEDI_ENABLE_CRIS_FSR_N20=1
JEDI_ENABLE_SEVIRI_M11=1

#-------------------------------------------------------------------------------
# 7b. Convert native restart files to the selected lower-resolution MPAS mesh.
#-------------------------------------------------------------------------------

lowres_restart_is_usable() {
  local file="$1"
  [ -s "$file" ] || return 1
  ncdump -h "$file" >/dev/null 2>&1 || return 1
  ncdump -h "$file" 2>/dev/null | grep -q "nCells = ${TARGET_NUM}" || return 1
  ncdump -h "$file" 2>/dev/null | grep -q "nEdges =" || return 1
  return 0
}

remap_restart_one_node() {
  local source_file="$1"
  local target_file="$2"
  local label="$3"
  local target_tmp="${target_file}.tmp.${SLURM_JOB_ID:-$$}"

  require_file "$source_file"
  require_file "$SOURCE_INVARIANT_FILE"
  require_file "$TARGET_INVARIANT_FILE"
  require_file "$JEDI_REMAP_EXE"

  mkdir -p "$(dirname "$target_file")"

  if lowres_restart_is_usable "$target_file" && [ "$target_file" -nt "$source_file" ]; then
    log "Reusing current low-resolution $label: $target_file"
    return 0
  fi

  rm -f "$target_tmp"

  log "Remapping $label on one node"
  log "Source restart: $source_file"
  log "Source mesh:    $SOURCE_INVARIANT_FILE"
  log "Target mesh:    $TARGET_INVARIANT_FILE"
  log "Target restart: $target_file"
  log "OpenMP threads: $JEDI_REMAP_THREADS"

  remap_cmd=(
    srun
    --exclusive
    -N 1
    -n 1
    --cpus-per-task="$JEDI_REMAP_THREADS"
    --cpu-bind=cores
    "$JEDI_REMAP_EXE"
    --source-mesh "$SOURCE_INVARIANT_FILE"
    --source-core "$source_file"
    --target-mesh "$TARGET_INVARIANT_FILE"
    --output "$target_tmp"
    --neighbors "$JEDI_REMAP_NEIGHBORS"
    --power "$JEDI_REMAP_POWER"
    --verbose
  )

  set +e
  OMP_NUM_THREADS="$JEDI_REMAP_THREADS" \
  OMP_PLACES=cores \
  OMP_PROC_BIND=spread \
  KMP_BLOCKTIME=0 \
    "${remap_cmd[@]}"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ] || die "MPAS remapping failed for $label with rc=$rc"
  lowres_restart_is_usable "$target_tmp" || \
    die "remapped $label is missing, unreadable, or has the wrong nCells: $target_tmp"

  mv -f "$target_tmp" "$target_file"
  require_file "$target_file"
  log "Completed low-resolution $label: $target_file"
}

prepare_low_resolution_restarts() {
  [ "$JEDI_REMAP_ENABLE" = "1" ] || {
    log "JEDI restart remapping disabled; using native mesh"
    return 0
  }

  command -v ncdump >/dev/null 2>&1 || die "ncdump is required for remap validation"

  remap_restart_one_node "$SOURCE_BG_FILE" "$LOWRES_BG_FILE" \
    "window-start background"

  # The middle-window state is required later as the complete template into
  # which JEDI diagnostic analysis fields are merged. It must therefore use
  # the same target mesh as the variational geometry and ensemble members.
  remap_restart_one_node "$SOURCE_AN_GUESS_FILE" "$LOWRES_AN_GUESS_FILE" \
    "middle-window restart"
}

validate_netcdf_target_cells() {
  local file="$1"
  local label="$2"
  local cells

  require_file "$file"
  cells="$(ncdump -h "$file" 2>/dev/null | sed -n 's/^[[:space:]]*nCells[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"

  [ -n "$cells" ] || die "$label has no readable nCells dimension: $file"
  [ "$cells" -eq "$NUM" ] || \
    die "$label mesh mismatch: nCells=$cells, expected target nCells=$NUM: $file"
}

#-------------------------------------------------------------------------------
# 8. Validate static inputs before entering the work directory.
#-------------------------------------------------------------------------------

require_file "$MPASJEDI_EXE"
require_file "$SOURCE_BG_FILE"
require_file "$SOURCE_AN_GUESS_FILE"
require_file "$SOURCE_INVARIANT_FILE"
if [ "$JEDI_REMAP_ENABLE" = "1" ]; then
  require_file "$TARGET_INVARIANT_FILE"
  require_file "$JEDI_REMAP_EXE"
fi

prepare_low_resolution_restarts

require_file "$BG_FILE"
require_file "$AN_GUESS_FILE"
require_file "$INVARIANT_FILE"
require_file "$TEMPLATE_YAML"
require_file "$JEDI_NAME_DIR/namelist.atmosphere"
require_file "$JEDI_NAME_DIR/streams.atmosphere"
require_file "$JEDI_RESOURCE_DIR/stream_list.atmosphere.control"
require_file "$JEDI_RESOURCE_DIR/stream_list.atmosphere.background"
require_file "$JEDI_RESOURCE_DIR/stream_list.atmosphere.ensemble"
require_file "$JEDI_RESOURCE_DIR/stream_list.atmosphere.analysis"
require_file "$JEDI_RESOURCE_DIR/geovars.yaml"
require_file "$JEDI_RESOURCE_DIR/keptvars.yaml"
require_file "$JEDI_OBSOP_NAME_MAP"
require_file "$STDDEV_FILE"
validate_netcdf_target_cells "$STDDEV_FILE" "STDDEV_FILE"
require_dir  "$CRTM_COEFFS_SRC"
require_dir  "$UFOCOEFF_CACHE"
command -v dcp >/dev/null 2>&1 || die "dcp is not available; load the mpifileutils module"
command -v ncks >/dev/null 2>&1 || die "ncks is not available"

if [ "$USE_FGAT_ENSEMBLE_B" = "1" ] || [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ]; then
  [ "$WIN_LEN" = "PT6H" ] || log "WARNING: ensemble modes are normally configured with WIN_LEN=PT6H"
  require_dir "$ENSEMBLE_BUMPLOC_DATA_DIR"
  require_dir "$STATIC_BUMPCOV_DATA_DIR"
  require_dir "$STATIC_VBAL_DATA_DIR"
  require_file "$STATIC_STDDEV_FILE"
  validate_netcdf_target_cells "$STATIC_STDDEV_FILE" "STATIC_STDDEV_FILE"

  python3 - "$ENSEMBLE_STATIC_WEIGHT" "$ENSEMBLE_FLOW_WEIGHT" <<'PYWEIGHTS'
import sys
static = float(sys.argv[1])
flow = float(sys.argv[2])
if static < 0.0 or flow < 0.0:
    raise SystemExit("ERROR: ensemble hybrid weights must be nonnegative")
if abs(static + flow - 1.0) > 1.0e-10:
    raise SystemExit(f"ERROR: ensemble hybrid weights sum to {static + flow}, not 1.0")
PYWEIGHTS

  command -v ncdump >/dev/null 2>&1 || die "ncdump is required to validate generated ensemble members"

  if [ "$ENSEMBLE_GENERATE_MEMBERS" = "1" ]; then
    require_file "$MPASJEDI_GEN_ENS_EXE"
    require_file "$PERT_TEMPLATE_SOURCE"
  else
    require_dir "$ENSEMBLE_ROOT"
  fi
fi

#-------------------------------------------------------------------------------
# 9. Prepare the work directory and link/copy all MPAS-JEDI runtime inputs.
#-------------------------------------------------------------------------------

safe_clean_workdir "$WORKDIR"
cd "$WORKDIR" || die "cannot enter runtime directory: $WORKDIR"

# Keep the exact ensemble-generator template used by this cycle in the common
# MPAS-JEDI runtime directory. Rendering is always performed from this local
# copy, never from the ensemble-output tree.
if [ "$USE_FGAT_ENSEMBLE_B" = "1" ] || [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ]; then
  cp -p "$PERT_TEMPLATE_SOURCE" "$PERT_TEMPLATE_YAML"
  require_file "$PERT_TEMPLATE_YAML"
fi

log "RUN_DATE=$RUN_DATE"
log "ANALYSIS_DATE=$ANALYSIS_DATE"
log "WIN_BEG_DATE=$WIN_BEG_DATE"
log "ANL_ISO=$ANL_ISO"
log "WIN_BEG_ISO=$WIN_BEG_ISO"
log "JEDI_VAR_MODE=$JEDI_VAR_MODE COST_TYPE=$COST_TYPE OUTER_LOOP_COUNT=$OUTER_LOOP_COUNT"
log "SOURCE_BG_FILE=$SOURCE_BG_FILE"
log "SOURCE_AN_GUESS_FILE=$SOURCE_AN_GUESS_FILE"
log "JEDI_REMAP_ENABLE=$JEDI_REMAP_ENABLE"
log "ENSEMBLE_LOWRESOLUTION=$ENSEMBLE_LOWRESOLUTION"
log "LOWRES_B_ROOT=$LOWRES_B_ROOT"
log "ENSEMBLE_MODEL_TSTEP=$ENSEMBLE_MODEL_TSTEP"
log "SOURCE_INVARIANT_FILE=$SOURCE_INVARIANT_FILE"
log "TARGET_INVARIANT_FILE=$TARGET_INVARIANT_FILE"
log "BG_FILE=$BG_FILE"
log "AN_GUESS_FILE=$AN_GUESS_FILE"
log "JEDI_MID_ANALYSIS_FILE=$JEDI_MID_ANALYSIS_FILE"
log "AN_ANALYSIS_FILE=$AN_ANALYSIS_FILE"
log "WORKDIR=$WORKDIR"
log "All MPAS-JEDI applications run from $WORKDIR"
log "TEMPLATE_YAML=$TEMPLATE_YAML"
if [ -e "$PERT_TEMPLATE_YAML" ]; then
  log "PERT_TEMPLATE_YAML=$PERT_TEMPLATE_YAML"
fi
log "VARBC_ROOT=$VARBC_ROOT"
log "OBS missing policy=$JEDI_OBS_MISSING_POLICY"
if [ "$USE_FGAT_ENSEMBLE_B" = "1" ] || [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ]; then
  log "Ensemble covariance mode enabled"
  log "USE_FGAT_ENSEMBLE_B=$USE_FGAT_ENSEMBLE_B"
  log "USE_4D_ENSEMBLE_TRAJECTORIES=$USE_4D_ENSEMBLE_TRAJECTORIES"
  log "ENSEMBLE_GENERATE_MEMBERS=$ENSEMBLE_GENERATE_MEMBERS"
  log "ENSEMBLE_MEMBERS=$ENSEMBLE_MEMBERS"
  log "ENSEMBLE_ROOT=$ENSEMBLE_ROOT"
  log "ENSEMBLE_FORECAST_LENGTH=$ENSEMBLE_FORECAST_LENGTH"
  log "ENSEMBLE_OUTPUT_FREQUENCY=$ENSEMBLE_OUTPUT_FREQUENCY"
  log "ENSEMBLE_STATIC_WEIGHT=$ENSEMBLE_STATIC_WEIGHT"
  log "ENSEMBLE_FLOW_WEIGHT=$ENSEMBLE_FLOW_WEIGHT"
  log "ENSEMBLE_BUMPLOC=$ENSEMBLE_BUMPLOC_DATA_DIR/$ENSEMBLE_BUMPLOC_FILES_PREFIX"
fi

link_file "$BG_FILE"        restart.nc
link_file "$BG_FILE"        init.nc
link_file "$BG_FILE"        background.nc
link_file "$BG_FILE"        "templateFields.${NUM}.nc"
link_file "$STDDEV_FILE"    control.nc
log "Linking invariant mesh: ${XNN}.${NUM}.invariant.nc -> $INVARIANT_FILE"
link_file "$INVARIANT_FILE" "${XNN}.${NUM}.invariant.nc"
link_file "$INVARIANT_FILE" invariant.nc

# Do not link the middle-window restart to analysis.nc and do not pre-create
# AN_ANALYSIS_FILE. JEDI writes its diagnostic analysis.* files independently.
rm -f analysis.nc
rm -f "$AN_ANALYSIS_FILE"

link_dir "$CRTM_COEFFS_SRC" crtm_coeffs_v3

rm -rf UFOCoeff

ln -sfn "$UFOCOEFF_CACHE" UFOCoeff
require_file UFOCoeff/CloudCoeff.bin
require_file UFOCoeff/AerosolCoeff.bin
require_file UFOCoeff/IGBP.IRland.EmisCoeff.bin
require_file UFOCoeff/FASTEM5.MWwater.EmisCoeff.bin

link_file "$JEDI_RESOURCE_DIR/geovars.yaml" geovars.yaml
link_file "$JEDI_RESOURCE_DIR/keptvars.yaml" keptvars.yaml
link_file "$JEDI_OBSOP_NAME_MAP" obsop_name_map.yaml

for stream in analysis background control ensemble; do
  link_file "$JEDI_RESOURCE_DIR/stream_list.atmosphere.${stream}" \
    "stream_list.atmosphere.${stream}"
done

PHYS="$MPASJEDI_BUNDLE_ROOT/build/mpas-jedi/test"
link_physics_files "$PHYS" CAM_ABS_DATA.DBL CAM_AEROPT_DATA.DBL \
        GENPARM.TBL LANDUSE.TBL OZONE_DAT.TBL OZONE_LAT.TBL \
        OZONE_PLEV.TBL RRTMG_LW_DATA RRTMG_LW_DATA.DBL \
        RRTMG_SW_DATA RRTMG_SW_DATA.DBL SOILPARM.TBL VEGPARM.TBL

#-------------------------------------------------------------------------------
# 10. Render namelist.atmosphere and streams.atmosphere from operational templates.
#-------------------------------------------------------------------------------

sed \
  -e "s|START_DATE|${MPAS_NML_YYYY}-${MPAS_NML_MM}-${MPAS_NML_DD}_${MPAS_NML_HH}:00:00|g" \
  -e "s|MPAS_FORECAST_LENGTH|$MPAS_FORECAST_LENGTH|g" \
  -e "s|MPAS_RESOLUTION|$MPAS_RESOLUTION|g" \
  -e "s|DT|$DT|g" \
  -e "s|DX|$DX|g" \
  -e "s|XNN|$XNN|g" \
  -e "s|NUM|$NUM|g" \
  "$JEDI_NAME_DIR/namelist.atmosphere" > namelist.atmosphere

sed \
  -e "s|XNN|$XNN|g" \
  -e "s|NUM|$NUM|g" \
  -e "s|MPAS_RESOLUTION|$MPAS_RESOLUTION|g" \
  "$JEDI_NAME_DIR/streams.atmosphere" > streams.atmosphere

# NCAR-style nonlinear trajectory initialization requires a native restart stream.
require_file restart.nc
grep -q 'name="restart"' streams.atmosphere || die "rendered streams.atmosphere has no restart stream"
grep -q 'filename_template="restart.nc"' streams.atmosphere || die "restart stream does not point to restart.nc"
grep -q 'config_do_restart[[:space:]]*=[[:space:]]*true' namelist.atmosphere || \
  die "rendered namelist.atmosphere is not configured for restart initialization"

#-------------------------------------------------------------------------------
# 11a. Static B and 4D-EnVar YAML helpers.
#-------------------------------------------------------------------------------

# NCAR/MPAS-JEDI 3.0.3 state-variable families using native MPAS variable names.
# 3DVAR:
#   Operator-rich 3D-Var state adapted from the 3.0.3 MPAS-JEDI reference: core + hydrometeors
#   + pressure_p + cldfrac + 2-m/roughness diagnostics.
# 3D-FGAT and 4D-FGAT:
#   FGAT nonlinear-model trajectory state: core + hydrometeors + pressure_p + w.
# 4D-EnsVar:
#   4D-EnVar state: core + pressure_p, no hydrometeors, no w, no t2m/znt.
state_variables_yaml() {
  case "$COST_TYPE" in
    3D-Var)
      cat <<'EOF'
    - temperature
    - spechum
    - uReconstructZonal
    - uReconstructMeridional
    - surface_pressure
    - qc
    - qi
    - qr
    - qs
    - qg
    - theta
    - rho
    - u
    - qv
    - pressure
    - landmask
    - xice
    - snowc
    - skintemp
    - ivgtyp
    - isltyp
    - snowh
    - snow
    - znt
    - t2m
    - vegfra
    - u10
    - v10
    - lai
    - smois
    - tslb
    - pressure_p
    - cldfrac
EOF
      ;;
    3D-FGAT|4D-Var)
      trajectory_variables_yaml
      ;;
    4D-Ens-Var)
      cat <<'EOF'
    - temperature
    - spechum
    - uReconstructZonal
    - uReconstructMeridional
    - surface_pressure
    - theta
    - rho
    - u
    - qv
    - pressure
    - landmask
    - xice
    - snowc
    - skintemp
    - ivgtyp
    - isltyp
    - snowh
    - snow
    - vegfra
    - u10
    - v10
    - lai
    - smois
    - tslb
    - pressure_p
    - cldfrac
EOF
      ;;
    *)
      die "internal error: unsupported COST_TYPE=$COST_TYPE in state_variables_yaml"
      ;;
  esac
}

trajectory_variables_yaml() {
  cat <<'EOF'
    - temperature
    - spechum
    - uReconstructZonal
    - uReconstructMeridional
    - surface_pressure
    - theta
    - rho
    - u
    - qv
    - pressure
    - landmask
    - xice
    - snowc
    - skintemp
    - ivgtyp
    - isltyp
    - qc
    - qi
    - qr
    - qs
    - qg
    - pressure_p
    - snowh
    - snow
    - vegfra
    - u10
    - v10
    - lai
    - smois
    - tslb
    - w
    - cldfrac
EOF
}

model_variables_yaml() {
  trajectory_variables_yaml
}

make_static_background_block() {
  if [ "$USE_MODEL_BLOCK" = "1" ]; then
    cat <<EOF
  background:
    state variables: *modvars
    filename: "./background.nc"
    date: '${BG_ISO}'
    stream name: background
EOF
  else
    cat <<EOF
  background:
    state variables: &stvars
$(state_variables_yaml)
    filename: "./background.nc"
    date: '${BG_ISO}'
    stream name: background
EOF
  fi
}

make_4densvar_background_block() {
  cat <<EOF
  background:
    states:
    - state variables: &stvars
$(state_variables_yaml)
      filename: "./background_t0.nc"
      date: '${WIN_BEG_ISO}'
      stream name: background
    - state variables: *stvars
      filename: "./background_t1.nc"
      date: '${ANL_ISO}'
      stream name: background
    - state variables: *stvars
      filename: "./background_t2.nc"
      date: '${WIN_END_ISO}'
      stream name: background
EOF
}

make_static_background_error_block() {
  cat <<EOF
  background error:
    covariance model: SABER
    saber central block:
      saber block name: BUMP_NICAS
      active variables: &ctlvars
      - stream_function
      - velocity_potential
      - temperature
      - spechum
      - surface_pressure
      read:
        nearest 3d level: bottom
        model:
          nearest 3d level: bottom
        io:
          data directory: ${STATIC_BUMPCOV_DATA_DIR}
          files prefix: ${STATIC_BUMPCOV_FILES_PREFIX}
        drivers:
          multivariate strategy: univariate
          read local nicas: true
          read global nicas: false
        grids:
        - model:
            variables:
            - stream_function
            - velocity_potential
            - temperature
            - spechum
            nearest 3d level: bottom
        - model:
            variables:
            - surface_pressure
            nearest 3d level: bottom

    saber outer blocks:
    - saber block name: StdDev
      read:
        model file:
          filename: ${STATIC_STDDEV_FILE}
          date: '${STDDEV_ISO}'
          stream name: control
          nearest 3d level: bottom

    - saber block name: BUMP_VerticalBalance
      read:
        nearest 3d level: bottom
        model:
          nearest 3d level: bottom
        io:
          data directory: ${STATIC_VBAL_DATA_DIR}
          files prefix: mpas
        drivers:
          read local sampling: true
          read global sampling: false
          read vertical balance: true
        vertical balance:
          nearest 3d level: bottom
          vbal:
          - balanced variable: velocity_potential
            unbalanced variable: stream_function
            diagonal regression: true
          - balanced variable: temperature
            unbalanced variable: stream_function
          - balanced variable: surface_pressure
            unbalanced variable: stream_function

    linear variable change:
      linear variable change name: Control2Analysis
      input variables: *ctlvars
      output variables: *incvars
EOF
}

ensemble_member_file_for_time() {
  local mem="$1" dt="$2"
  printf "%s/mem%s/EnsForCov.%s-%s-%s_%s.00.00.nc" \
    "$ENSEMBLE_ROOT" "$mem" "${dt:0:4}" "${dt:4:2}" "${dt:6:2}" "${dt:8:2}"
}

validate_ensemble_member_file() {
  local file="$1"
  require_file "$file"
  [ -s "$file" ] || die "empty ensemble member file: $file"
  command -v ncdump >/dev/null 2>&1 && ncdump -h "$file" >/dev/null 2>&1 || \
    die "unreadable NetCDF ensemble member: $file"
}

make_ensemble_members_yaml() {
  local i f0 f1 f2

  for ((i=1; i<=ENSEMBLE_MEMBERS; i++)); do
    f0="$(ensemble_member_file_for_time "$i" "$WIN_BEG_DATE")"
    f1="$(ensemble_member_file_for_time "$i" "$ANALYSIS_DATE")"
    f2="$(ensemble_member_file_for_time "$i" "$WIN_END_DATE")"

    validate_ensemble_member_file "$f0"
    validate_ensemble_member_file "$f1"
    validate_ensemble_member_file "$f2"

    cat <<EOF
        - states:
          - filename: ${f0}
            date: '${WIN_BEG_ISO}'
            state variables: *incvars
            stream name: ensemble
          - filename: ${f1}
            date: '${ANL_ISO}'
            state variables: *incvars
            stream name: ensemble
          - filename: ${f2}
            date: '${WIN_END_ISO}'
            state variables: *incvars
            stream name: ensemble
EOF
  done
}

make_hybrid_background_error_block() {
  local stddev_date="$1"
  local members_yaml
  members_yaml="$(make_ensemble_members_yaml)"

  cat <<EOF
  background error:
    covariance model: hybrid
    components:

    - covariance:
        covariance model: SABER
        saber central block:
          saber block name: BUMP_NICAS
          active variables: &ctlvars
          - stream_function
          - velocity_potential
          - temperature
          - spechum
          - surface_pressure
          read:
            nearest 3d level: bottom
            model:
              nearest 3d level: bottom
            io:
              data directory: ${STATIC_BUMPCOV_DATA_DIR}
              files prefix: ${STATIC_BUMPCOV_FILES_PREFIX}
            drivers:
              multivariate strategy: univariate
              read local nicas: true
              read global nicas: false
            grids:
            - model:
                variables:
                - stream_function
                - velocity_potential
                - temperature
                - spechum
                nearest 3d level: bottom
            - model:
                variables:
                - surface_pressure
                nearest 3d level: bottom

        saber outer blocks:
        - saber block name: StdDev
          read:
            model file:
              filename: ${STATIC_STDDEV_FILE}
              date: '${stddev_date}'
              stream name: control
              nearest 3d level: bottom

        - saber block name: BUMP_VerticalBalance
          read:
            nearest 3d level: bottom
            model:
              nearest 3d level: bottom
            io:
              data directory: ${STATIC_VBAL_DATA_DIR}
              files prefix: mpas
            drivers:
              read local sampling: true
              read global sampling: false
              read vertical balance: true
            vertical balance:
              nearest 3d level: bottom
              vbal:
              - balanced variable: velocity_potential
                unbalanced variable: stream_function
                diagonal regression: true
              - balanced variable: temperature
                unbalanced variable: stream_function
              - balanced variable: surface_pressure
                unbalanced variable: stream_function

        linear variable change:
          linear variable change name: Control2Analysis
          input variables: *ctlvars
          output variables: *incvars

      weight:
        value: ${ENSEMBLE_STATIC_WEIGHT}

    - covariance:
        covariance model: ensemble
        localization:
          localization method: SABER
          saber central block:
            saber block name: BUMP_NICAS
            active variables: *incvars
            read:
              nearest 3d level: bottom
              model:
                nearest 3d level: bottom
              io:
                data directory: ${ENSEMBLE_BUMPLOC_DATA_DIR}
                files prefix: ${ENSEMBLE_BUMPLOC_FILES_PREFIX}
              drivers:
                multivariate strategy: duplicated
                read local nicas: true
                read global nicas: false
        members:
${members_yaml}

      weight:
        value: ${ENSEMBLE_FLOW_WEIGHT}
EOF
}

ensemble_file_is_usable() {
  local file="$1"

  [ -s "$file" ] || return 1
  ncdump -h "$file" >/dev/null 2>&1 || return 1
  ncdump -h "$file" 2>/dev/null | grep -q "nCells = ${TARGET_NUM}" || return 1

  return 0
}

ensemble_is_complete() {
  local i dt file missing=0

  [ -d "$ENSEMBLE_ROOT" ] || {
    log "Ensemble directory does not exist: $ENSEMBLE_ROOT"
    return 1
  }

  for ((i=1; i<=ENSEMBLE_MEMBERS; i++)); do
    for dt in "$WIN_BEG_DATE" "$ANALYSIS_DATE" "$WIN_END_DATE"; do
      file="$(ensemble_member_file_for_time "$i" "$dt")"
      if ! ensemble_file_is_usable "$file"; then
        log "Missing or unreadable ensemble member: $file"
        missing=1
      fi
    done
  done

  [ "$missing" -eq 0 ]
}

render_ensemble_pert_yaml() {
  [ "$USE_FGAT_ENSEMBLE_B" = "1" ] || \
  [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ] || return 0

  [ "$ENSEMBLE_GENERATE_MEMBERS" = "1" ] || return 0

  log "Preparing clean ensemble directory: $ENSEMBLE_ROOT"

  rm -rf "$ENSEMBLE_ROOT"
  mkdir -p "$ENSEMBLE_ROOT"

  # With "include control: true", MPAS-JEDI writes the unperturbed
  # control trajectory as member 0.
  mkdir -p "$ENSEMBLE_ROOT/mem0"
  require_dir "$ENSEMBLE_ROOT/mem0"

  local i

  for ((i=1; i<=ENSEMBLE_MEMBERS; i++)); do
    mkdir -p "$ENSEMBLE_ROOT/mem${i}"
  done

  [ "$PWD" = "$WORKDIR" ] ||     die "ensemble YAML must be rendered from WORKDIR=$WORKDIR; current directory is $PWD"

  log "Rendering $WORKDIR/gen_ens_pert_B.yaml from $PERT_TEMPLATE_YAML"

  sed \
    -e "s|__BG_ISO__|$BG_ISO|g" \
    -e "s|__FGAT_TSTEP__|$FGAT_TSTEP|g" \
    -e "s|__ENSEMBLE_MEMBERS__|$ENSEMBLE_MEMBERS|g" \
    -e "s|__ENSEMBLE_FORECAST_LENGTH__|$ENSEMBLE_FORECAST_LENGTH|g" \
    -e "s|__ENSEMBLE_OUTPUT_FREQUENCY__|$ENSEMBLE_OUTPUT_FREQUENCY|g" \
    -e "s|__ENSEMBLE_ROOT__|$ENSEMBLE_ROOT|g" \
    -e "s|__STATIC_BUMPCOV_DATA_DIR__|$STATIC_BUMPCOV_DATA_DIR|g" \
    -e "s|__STATIC_BUMPCOV_FILES_PREFIX__|$STATIC_BUMPCOV_FILES_PREFIX|g" \
    -e "s|__STATIC_STDDEV_FILE__|$STATIC_STDDEV_FILE|g" \
    -e "s|__STATIC_VBAL_DATA_DIR__|$STATIC_VBAL_DATA_DIR|g" \
    -e "s|__ENSEMBLE_MODEL_TSTEP__|$ENSEMBLE_MODEL_TSTEP|g" \
    "$PERT_TEMPLATE_YAML" > gen_ens_pert_B.yaml

  require_file gen_ens_pert_B.yaml

  if grep -q '__[A-Z0-9_][A-Z0-9_]*__' gen_ens_pert_B.yaml; then
    grep -n '__[A-Z0-9_][A-Z0-9_]*__' gen_ens_pert_B.yaml || true
    die "unresolved placeholder remains in gen_ens_pert_B.yaml"
  fi

  grep -q '^initial condition:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no initial condition block"

  if grep -q '^background:' gen_ens_pert_B.yaml; then
    die "gen_ens_pert_B.yaml must not contain a top-level background block"
  fi

  grep -q '^forecast length:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no forecast length"

  grep -q '^members:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no members setting"

  grep -q '^background error:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no background error block"

  grep -q '^model:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no MPAS model block"

  grep -q '^output:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no ensemble output block"

  grep -q '^perturbed variables:' gen_ens_pert_B.yaml || \
    die "gen_ens_pert_B.yaml has no perturbed variables block"

  # Keep the runtime YAML in WORKDIR for inspection. Also archive an exact
  # cycle copy beside the ensemble output without changing directories.
  cp -p "$WORKDIR/gen_ens_pert_B.yaml"     "$ENSEMBLE_ROOT/gen_ens_pert_B.yaml"

  require_file "$WORKDIR/pert.303.yaml"
  require_file "$WORKDIR/gen_ens_pert_B.yaml"
}

validate_generated_ensemble() {
  local i dt

  log "Validating generated ensemble files"
  for ((i=1; i<=ENSEMBLE_MEMBERS; i++)); do
    for dt in "$WIN_BEG_DATE" "$ANALYSIS_DATE" "$WIN_END_DATE"; do
      validate_ensemble_member_file \
        "$(ensemble_member_file_for_time "$i" "$dt")"
    done
  done
}

run_ensemble_generation() {
  [ "$USE_FGAT_ENSEMBLE_B" = "1" ] || \
  [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ] || return 0

  cd "$WORKDIR" || \
    die "cannot enter ensemble-generation runtime directory: $WORKDIR"

  log "Checking whether the required ensemble already exists"

  if ensemble_is_complete; then
    log "Complete ensemble found; skipping mpasjedi_gen_ens_pert_B.x"
    log "Reusing ensemble from $ENSEMBLE_ROOT"

    validate_generated_ensemble

    log "All required ensemble files are present and readable"
    return 0
  fi

  log "Required ensemble is incomplete"
  log "A clean ensemble will be generated before MPAS-JEDI analysis"

  # ENSEMBLE_GENERATE_MEMBERS is retained as an explicit safety switch.
  # The normal restartable behavior is obtained with its default value of 1.
  [ "$ENSEMBLE_GENERATE_MEMBERS" = "1" ] || \
    die "ensemble is incomplete and ENSEMBLE_GENERATE_MEMBERS=$ENSEMBLE_GENERATE_MEMBERS"

  render_ensemble_pert_yaml

  cd "$WORKDIR" || \
    die "cannot enter ensemble-generation runtime directory: $WORKDIR"

  log "Starting NCAR ensemble perturbation and nonlinear forecasts"
  log "Working directory: $PWD"
  log "Executable: $MPASJEDI_GEN_ENS_EXE"
  log "Generator YAML: $WORKDIR/gen_ens_pert_B.yaml"

  [ "$PWD" = "$WORKDIR" ] || \
    die "generator must run from $WORKDIR; current directory is $PWD"

  set +e

  srun \
    --label \
    --cpu-bind=cores \
    -n "$SLURM_NTASKS" \
    --cpus-per-task="$SLURM_CPUS_PER_TASK" \
    "$MPASJEDI_GEN_ENS_EXE" \
    "$WORKDIR/gen_ens_pert_B.yaml"

  local rc=$?

  set -e

  [ "$rc" -eq 0 ] || \
    die "mpasjedi_gen_ens_pert_B.x failed with rc=$rc"

  log "Ensemble generator completed successfully"

  # Perform a full post-generation validation before analysis is allowed.
  validate_generated_ensemble

  log "All required ensemble files are present and readable"
  log "Preserving ensemble-generation runtime files in $WORKDIR"
}

link_4densvar_background_states() {
  [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ] || return 0

  local b0 b1 b2
  b0="$BG_FILE"
  b1="$AN_GUESS_FILE"
  b2="$ASSIM_ROOT/restart.${WIN_END_DATE:0:4}-${WIN_END_DATE:4:2}-${WIN_END_DATE:6:2}_${WIN_END_DATE:8:2}:00:00.nc"

  require_file "$b0"
  require_file "$b1"
  require_file "$b2"

  link_file "$b0" background_t0.nc
  link_file "$b1" background_t1.nc
  link_file "$b2" background_t2.nc
}

#-------------------------------------------------------------------------------
# 11. Render the YAML template, including dynamic variational iterations.
#-------------------------------------------------------------------------------

validate_obs_template_markers "$TEMPLATE_YAML"

make_variational_iterations() {
  local i
  for ((i=1; i<=OUTER_LOOP_COUNT; i++)); do
    cat <<EOF
  - geometry:
      nml_file: "./namelist.atmosphere"
      streams_file: "./streams.atmosphere"
EOF
    if [ "$USE_LINEAR_MODEL" = "1" ]; then
      cat <<EOF
    linear model:
      name: ${JEDI_LINEAR_MODEL_NAME}
      increment variables: *incvars
      tstep: ${FGAT_TSTEP}
EOF
    fi
    cat <<EOF
    ninner: ${JEDI_NINNER}
    gradient norm reduction: ${JEDI_GRADIENT_NORM_REDUCTION}
    diagnostics:
      departures: ombg
EOF
  done
}

run_ensemble_generation
link_4densvar_background_states

VARIATIONAL_ITERATIONS="$(cat <<EOF
  minimizer:
    algorithm: DRPCG
  iterations:
$(make_variational_iterations)
EOF
)"
export VARIATIONAL_ITERATIONS

if [ "$USE_4D_ENSEMBLE_TRAJECTORIES" = "1" ]; then
  BACKGROUND_BLOCK="$(make_4densvar_background_block)"
  BACKGROUND_ERROR_BLOCK="$(make_hybrid_background_error_block "$ANL_ISO")"
elif [ "$USE_FGAT_ENSEMBLE_B" = "1" ]; then
  BACKGROUND_BLOCK="$(make_static_background_block)"
  BACKGROUND_ERROR_BLOCK="$(make_hybrid_background_error_block "$STDDEV_ISO")"
else
  BACKGROUND_BLOCK="$(make_static_background_block)"
  BACKGROUND_ERROR_BLOCK="$(make_static_background_error_block)"
fi
export BACKGROUND_BLOCK
export BACKGROUND_ERROR_BLOCK

sed \
  -e "s|__COST_TYPE__|$COST_TYPE|g" \
  -e "s|__WIN_BEG_ISO__|$WIN_BEG_ISO|g" \
  -e "s|__BG_ISO__|$BG_ISO|g" \
  -e "s|__WIN_LEN__|$WIN_LEN|g" \
  -e "s|__FGAT_TSTEP__|$FGAT_TSTEP|g" \
  -e "s|__ANL_ISO__|$ANL_ISO|g" \
  -e "s|__ANL_TAG_H5__|$ANL_TAG_H5|g" \
  -e "s|__AMSUA_METOP_B_BIAS_OUT__|$AMSUA_METOP_B_BIAS_OUT|g" \
  -e "s|__AMSUA_METOP_B_COV_OUT__|$AMSUA_METOP_B_COV_OUT|g" \
  -e "s|__AMSUA_METOP_C_BIAS_OUT__|$AMSUA_METOP_C_BIAS_OUT|g" \
  -e "s|__AMSUA_METOP_C_COV_OUT__|$AMSUA_METOP_C_COV_OUT|g" \
  -e "s|__MHS_METOP_B_BIAS_OUT__|$MHS_METOP_B_BIAS_OUT|g" \
  -e "s|__MHS_METOP_B_COV_OUT__|$MHS_METOP_B_COV_OUT|g" \
  -e "s|__MHS_METOP_C_BIAS_OUT__|$MHS_METOP_C_BIAS_OUT|g" \
  -e "s|__MHS_METOP_C_COV_OUT__|$MHS_METOP_C_COV_OUT|g" \
  -e "s|__AMSUA_N18_BIAS_IN__|$AMSUA_N18_BIAS_IN|g" \
  -e "s|__AMSUA_N18_BIAS_OUT__|$AMSUA_N18_BIAS_OUT|g" \
  -e "s|__ATMS_NPP_BIAS_IN__|$ATMS_NPP_BIAS_IN|g" \
  -e "s|__ATMS_NPP_BIAS_OUT__|$ATMS_NPP_BIAS_OUT|g" \
  -e "s|__ATMS_N20_BIAS_IN__|$ATMS_N20_BIAS_IN|g" \
  -e "s|__ATMS_N20_BIAS_OUT__|$ATMS_N20_BIAS_OUT|g" \
  -e "s|__IASI_METOP_A_BIAS_IN__|$IASI_METOP_A_BIAS_IN|g" \
  -e "s|__IASI_METOP_A_BIAS_OUT__|$IASI_METOP_A_BIAS_OUT|g" \
  -e "s|__IASI_METOP_B_BIAS_OUT__|$IASI_METOP_B_BIAS_OUT|g" \
  -e "s|__IASI_METOP_B_COV_OUT__|$IASI_METOP_B_COV_OUT|g" \
  -e "s|__CRIS_FSR_NPP_BIAS_IN__|$CRIS_FSR_NPP_BIAS_IN|g" \
  -e "s|__CRIS_FSR_NPP_BIAS_OUT__|$CRIS_FSR_NPP_BIAS_OUT|g" \
  -e "s|__CRIS_FSR_N20_BIAS_IN__|$CRIS_FSR_N20_BIAS_IN|g" \
  -e "s|__CRIS_FSR_N20_BIAS_OUT__|$CRIS_FSR_N20_BIAS_OUT|g" \
  -e "s|__SEVIRI_M11_BIAS_IN__|$SEVIRI_M11_BIAS_IN|g" \
  -e "s|__SEVIRI_M11_BIAS_OUT__|$SEVIRI_M11_BIAS_OUT|g" \
  -e "s|__AMSUA_METOP_B_TLAPMEAN__|$AMSUA_METOP_B_TLAPMEAN|g" \
  -e "s|__AMSUA_METOP_C_TLAPMEAN__|$AMSUA_METOP_C_TLAPMEAN|g" \
  -e "s|__MHS_METOP_B_TLAPMEAN__|$MHS_METOP_B_TLAPMEAN|g" \
  -e "s|__MHS_METOP_C_TLAPMEAN__|$MHS_METOP_C_TLAPMEAN|g" \
  -e "s|__IASI_METOP_B_TLAPMEAN__|$IASI_METOP_B_TLAPMEAN|g" \
  "$TEMPLATE_YAML" > jedi.yaml

python3 - <<'PY'
from pathlib import Path
import os
import re

p = Path("jedi.yaml")
s = p.read_text()

s = s.replace("__VARIATIONAL_ITERATIONS__", os.environ["VARIATIONAL_ITERATIONS"])

for key in ("AMSUA_METOP_B", "AMSUA_METOP_C", "MHS_METOP_B", "MHS_METOP_C", "IASI_METOP_B"):
    s = s.replace(f"__{key}_BIAS_INPUT_BLOCK__", os.environ.get(f"{key}_BIAS_INPUT_BLOCK", ""))
    s = s.replace(f"__{key}_COV_PRIOR_BLOCK__", os.environ.get(f"{key}_COV_PRIOR_BLOCK", ""))

bg = os.environ["BACKGROUND_BLOCK"].rstrip()
be = os.environ["BACKGROUND_ERROR_BLOCK"].rstrip()

if "__BACKGROUND_BLOCK__" in s:
    s = s.replace("__BACKGROUND_BLOCK__", bg)
    s = s.replace("__BACKGROUND_ERROR_BLOCK__", be)
else:
    # The operational template contains a literal single-state "background:"
    # followed by the placeholder "__BACKGROUND_ERROR_BLOCK__".
    # Replace both together so 4D-Ens-Var gets "background: states:" and
    # the deterministic modes keep their normal single-state background.
    pattern = r"\n  background:\n.*?\n__BACKGROUND_ERROR_BLOCK__"
    repl = "\n" + bg + "\n\n" + be
    s, n = re.subn(pattern, repl, s, count=1, flags=re.S)
    if n == 0:
        s = s.replace("__BACKGROUND_ERROR_BLOCK__", be)

p.write_text(s)
PY

if [ "$USE_MODEL_BLOCK" = "0" ]; then
  remove_yaml_block MODEL_BLOCK jedi.yaml
  log "$JEDI_VAR_MODE: removed model block"
else
  sed -i '/#<MODEL_BLOCK>/d; /#<\/MODEL_BLOCK>/d' jedi.yaml
  log "$JEDI_VAR_MODE: keeping model block"
fi

#-------------------------------------------------------------------------------
# 12. Enable available observation spaces and remove missing/disabled blocks.
#-------------------------------------------------------------------------------

while IFS='|' read -r tag enabled source_name local_name; do
  enable_or_remove_obs "$tag" "$enabled" "$source_name" "$local_name"
done <<EOF
OBS_AIRCRAFT|$JEDI_ENABLE_AIRCRAFT|aircraft_obs|aircraft_obs_${ANL_TAG_H5}.h5
OBS_GNSSRO|$JEDI_ENABLE_GNSSRO|gnssro_obs|gnssro_obs_${ANL_TAG_H5}.h5
OBS_SATWIND|$JEDI_ENABLE_SATWIND|satwind_obs|satwind_obs_${ANL_TAG_H5}.h5
OBS_SONDES|$JEDI_ENABLE_SONDES|sondes_obs|sondes_obs_${ANL_TAG_H5}.h5
OBS_PROFILER|$JEDI_ENABLE_PROFILER|profiler_obs|profiler_obs_${ANL_TAG_H5}.h5
OBS_ASCAT|$JEDI_ENABLE_ASCAT|ascat_obs|ascat_obs_${ANL_TAG_H5}.h5
OBS_SATWND|$JEDI_ENABLE_SATWND|satwnd_obs|satwnd_obs_${ANL_TAG_H5}.h5
EOF

if [ "$JEDI_ENABLE_SFC" != "1" ]; then
  OBS_ACTIVE[OBS_SFC_TQPS]=0
  remove_yaml_block OBS_SFC_TQPS jedi.yaml
  remove_yaml_block OBS_SFC_WIND jedi.yaml
  log "OBS SFC disabled: OBS_SFC_TQPS and OBS_SFC_WIND removed"
else
  src="$JEDI_ROOT/sfc_obs_${ANL_TAG_H5}.h5"
  if [ ! -s "$src" ]; then
    if [ "$JEDI_OBS_MISSING_POLICY" = "skip" ]; then
      OBS_ACTIVE[OBS_SFC_TQPS]=0
      remove_yaml_block OBS_SFC_TQPS jedi.yaml
      remove_yaml_block OBS_SFC_WIND jedi.yaml
      log "OBS SFC enabled but missing; skipped: $src"
    else
      die "OBS SFC enabled but file is missing: $src"
    fi
  else
    ln -sf "$src" "sfc_obs_${ANL_TAG_H5}.h5"
    require_file "sfc_obs_${ANL_TAG_H5}.h5"
    OBS_ACTIVE[OBS_SFC_TQPS]=1
    log "OBS SFC enabled: sfc_obs_${ANL_TAG_H5}.h5 -> $src"
  fi
fi

while IFS='|' read -r tag enabled source_name local_name; do
  enable_or_remove_obs "$tag" "$enabled" "$source_name" "$local_name"
done <<EOF
OBS_AMSUA_METOP_B|$JEDI_ENABLE_AMSUA_METOP_B|amsua_metop-b_obs|amsua_metop-b_obs_${ANL_TAG_H5}.h5
OBS_AMSUA_METOP_C|$JEDI_ENABLE_AMSUA_METOP_C|amsua_metop-c_obs|amsua_metop-c_obs_${ANL_TAG_H5}.h5
OBS_MHS_METOP_B|$JEDI_ENABLE_MHS_METOP_B|mhs_metop-b_obs|mhs_metop-b_obs_${ANL_TAG_H5}.h5
OBS_MHS_METOP_C|$JEDI_ENABLE_MHS_METOP_C|mhs_metop-c_obs|mhs_metop-c_obs_${ANL_TAG_H5}.h5
OBS_IASI_METOP_B|$JEDI_ENABLE_IASI_METOP_B|iasi_metop-b_obs|iasi_metop-b_obs_${ANL_TAG_H5}.h5
OBS_IASI_METOP_C|$JEDI_ENABLE_IASI_METOP_C|iasi_metop-c_obs|iasi_metop-c_obs_${ANL_TAG_H5}.h5
OBS_AMSUA_N18|$JEDI_ENABLE_AMSUA_N18|amsua_n18_obs|amsua_n18_obs_${ANL_TAG_H5}.h5
OBS_ATMS_NPP|$JEDI_ENABLE_ATMS_NPP|atms_npp_obs|atms_npp_obs_${ANL_TAG_H5}.h5
OBS_ATMS_N20|$JEDI_ENABLE_ATMS_N20|atms_n20_obs|atms_n20_obs_${ANL_TAG_H5}.h5
OBS_IASI_METOP_A|$JEDI_ENABLE_IASI_METOP_A|iasi_metop-a_obs|iasi_metop-a_obs_${ANL_TAG_H5}.h5
OBS_CRIS_FSR_NPP|$JEDI_ENABLE_CRIS_FSR_NPP|cris-fsr_npp_obs|cris-fsr_npp_obs_${ANL_TAG_H5}.h5
OBS_CRIS_FSR_N20|$JEDI_ENABLE_CRIS_FSR_N20|cris-fsr_n20_obs|cris-fsr_n20_obs_${ANL_TAG_H5}.h5
OBS_SEVIRI_M11|$JEDI_ENABLE_SEVIRI_M11|seviri_m11_obs|seviri_m11_obs_${ANL_TAG_H5}.h5
EOF

sed -i '/#<OBS_/d; /#<\/OBS_/d' jedi.yaml

while IFS='|' read -r tag observer_name; do
  assert_obs_effective_result "$tag" "$observer_name"
done <<'EOF'
OBS_SONDES|Radiosonde
OBS_AIRCRAFT|Aircraft
OBS_GNSSRO|GnssroRefNCEP
OBS_SATWIND|Satwind
OBS_PROFILER|Profiler
OBS_SATWND|Satwnd
OBS_ASCAT|Ascat
OBS_SFC_TQPS|SfcPCorrected
OBS_AMSUA_METOP_B|amsua_metop-b
OBS_AMSUA_METOP_C|amsua_metop-c
OBS_MHS_METOP_B|mhs_metop-b
OBS_MHS_METOP_C|mhs_metop-c
OBS_IASI_METOP_B|iasi_metop-b
OBS_IASI_METOP_C|iasi_metop-c
OBS_AMSUA_N18|amsua_n18
OBS_ATMS_NPP|atms_npp
OBS_ATMS_N20|atms_n20
OBS_IASI_METOP_A|iasi_metop-a
OBS_CRIS_FSR_NPP|cris-fsr_npp
OBS_CRIS_FSR_N20|cris-fsr_n20
OBS_SEVIRI_M11|seviri_m11
EOF

#-------------------------------------------------------------------------------
# 13. Validate the generated YAML and coefficient files after pruning obs blocks.
#-------------------------------------------------------------------------------

grep -q "#<OBS_\|#</OBS_" jedi.yaml && die "observation block markers still present in final YAML"

if grep -q "__[A-Z0-9_][A-Z0-9_]*__" jedi.yaml; then
  grep -n "__[A-Z0-9_][A-Z0-9_]*__" jedi.yaml >&2 || true
  die "invalid generated YAML: unresolved template placeholder remains"
fi

if grep -q "\*iasi_metop_a_channels\|\*cris_fsr_channels\|\*crtmobsoper\|\*crtmobsopts" jedi.yaml; then
  die "invalid generated YAML: unresolved cross-block YAML anchor remains"
fi

grep -q "^[[:space:]]*- obs space:" jedi.yaml || die "no observation blocks remain in final YAML"

for s in iasi_metop-b iasi_metop-c amsua_metop-b amsua_metop-c mhs_metop-b mhs_metop-c; do
  if grep -q "Sensor_ID: ${s}" jedi.yaml; then
    require_file "UFOCoeff/${s}.SpcCoeff.bin"
    require_file "UFOCoeff/${s}.TauCoeff.bin"
  fi
done

# VarBC priors are optional: absence of either member of a pair triggers cold start.

grep -q "Sensor_ID: amsua_metop-b" jedi.yaml && require_file "$AMSUA_METOP_B_TLAPMEAN"
grep -q "Sensor_ID: amsua_metop-c" jedi.yaml && require_file "$AMSUA_METOP_C_TLAPMEAN"
grep -q "Sensor_ID: mhs_metop-b"   jedi.yaml && require_file "$MHS_METOP_B_TLAPMEAN"
grep -q "Sensor_ID: mhs_metop-c"   jedi.yaml && require_file "$MHS_METOP_C_TLAPMEAN"
grep -q "Sensor_ID: iasi_metop-b"  jedi.yaml && require_file "$IASI_METOP_B_TLAPMEAN"

validate_final_observation_inputs jedi.yaml

log "Enabled observers in final YAML:"
log_final_observers jedi.yaml | tee -a "$RUNLOG"

# Validate the exact intended science configuration before launching all ranks:
# deterministic 4D-Var/4D-FGAT plus a hybrid static + ensemble B.
if [ "$USE_FGAT_ENSEMBLE_B" = "1" ]; then
  python3 - "$ENSEMBLE_MEMBERS" "$WIN_BEG_ISO" "$ANL_ISO" "$WIN_END_ISO" <<'PYHYBRIDVALIDATE'
from pathlib import Path
import sys
import yaml

expected_members = int(sys.argv[1])
expected_dates = list(sys.argv[2:5])

with Path("jedi.yaml").open(encoding="utf-8") as stream:
    cfg = yaml.safe_load(stream)

cost = cfg["cost function"]
assert cost["cost type"] == "4D-Var", \
    f"expected cost type 4D-Var, found {cost.get('cost type')}"
assert "subwindow" not in cost, \
    "pure 4D-Ens-Var key 'subwindow' must not be present"
assert "parallel subwindows" not in cost, \
    "pure 4D-Ens-Var key 'parallel subwindows' must not be present"

background = cost["background"]
assert "states" not in background, \
    "deterministic 4D-Var background must be a single initial state"
assert background.get("filename") == "./background.nc", \
    f"unexpected deterministic background: {background.get('filename')}"
assert background.get("date") == expected_dates[0], \
    f"background date must be window beginning {expected_dates[0]}"

model = cost.get("model")
assert isinstance(model, dict) and model.get("name") == "MPAS", \
    "nonlinear MPAS model block is missing"

be = cost["background error"]
assert be.get("covariance model") == "hybrid", \
    "background error must use covariance model: hybrid"
components = be.get("components", [])
assert len(components) == 2, \
    f"hybrid B must contain exactly 2 components, found {len(components)}"
assert components[0]["covariance"].get("covariance model") == "SABER", \
    "first hybrid component must be static SABER"
ensemble = components[1]["covariance"]
assert ensemble.get("covariance model") == "ensemble", \
    "second hybrid component must be ensemble covariance"
members = ensemble.get("members", [])
assert len(members) == expected_members, \
    f"expected {expected_members} ensemble members, found {len(members)}"

for member_number, member in enumerate(members, start=1):
    states = member.get("states", [])
    assert len(states) == 3, \
        f"member {member_number} must contain 3 trajectory states"
    dates = [state.get("date") for state in states]
    assert dates == expected_dates, \
        f"member {member_number} dates {dates} differ from {expected_dates}"
    for state in states:
        assert state.get("state variables"), \
            f"member {member_number} has an empty state-variable list"

print("PASS: deterministic cost type is 4D-Var")
print("PASS: single MPAS background and nonlinear trajectory retained")
print("PASS: background error has static SABER + ensemble components")
print(f"PASS: {expected_members} ensemble trajectories x 3 times")
print("PASS: ensemble trajectories occur only inside background error")
PYHYBRIDVALIDATE
fi

#-------------------------------------------------------------------------------
# 14. Run MPAS-JEDI variational assimilation.
#-------------------------------------------------------------------------------

log "Running: $MPASJEDI_EXE jedi.yaml"

require_file invariant.nc

ln -sf "$LOGDIR/log.atmosphere.jedi.0000.out" log.atmosphere.0000.out

if echo "${LD_LIBRARY_PATH}" | tr ':' '\n' | grep -E '/scratch/lus/dev|paraview|/ncl|/model/src/(ioda|iodaconv|jedi)' >/dev/null; then
  echo "ERROR: LD_LIBRARY_PATH still contains old/polluting paths:" >&2
  echo "${LD_LIBRARY_PATH}" | tr ':' '\n' | grep -E '/scratch/lus/dev|paraview|/ncl|/model/src/(ioda|iodaconv|jedi)' >&2
  exit 2
fi

set +e
srun --label --cpu-bind=cores \
  -n "$SLURM_NTASKS" \
  --cpus-per-task="$SLURM_CPUS_PER_TASK" \
  "$MPASJEDI_EXE" jedi.yaml
rc=$?
set -e

log "mpasjedi_variational.x rc=$rc"

#-------------------------------------------------------------------------------
# 15. Save the completed analysis as the cycle analysis file.
#-------------------------------------------------------------------------------

if [ "$rc" -eq 0 ]; then
  while IFS='|' read -r tag sensor bcoeff_out cov_out bcoeff_store cov_store; do
    if [ "${OBS_ACTIVE[$tag]:-0}" = "1" ]; then
      require_file "$bcoeff_out"
      require_file "$cov_out"
      [ -s "$bcoeff_out" ] || die "generated VarBC coefficient file is empty: $bcoeff_out"
      [ -s "$cov_out" ] || die "generated VarBC covariance file is empty: $cov_out"

      # Preserve the previous cycle until both new files have been validated.
      install -m 0644 "$bcoeff_out" "${bcoeff_store}.new"
      install -m 0644 "$cov_out" "${cov_store}.new"
      mv -f "${bcoeff_store}.new" "$bcoeff_store"
      mv -f "${cov_store}.new" "$cov_store"
      log "VarBC $sensor updated: $bcoeff_store ; $cov_store"
    fi
  done <<EOF
OBS_AMSUA_METOP_B|amsua_metop-b|$AMSUA_METOP_B_BIAS_OUT|$AMSUA_METOP_B_COV_OUT|$AMSUA_METOP_B_BIAS_STORE|$AMSUA_METOP_B_COV_STORE
OBS_AMSUA_METOP_C|amsua_metop-c|$AMSUA_METOP_C_BIAS_OUT|$AMSUA_METOP_C_COV_OUT|$AMSUA_METOP_C_BIAS_STORE|$AMSUA_METOP_C_COV_STORE
OBS_MHS_METOP_B|mhs_metop-b|$MHS_METOP_B_BIAS_OUT|$MHS_METOP_B_COV_OUT|$MHS_METOP_B_BIAS_STORE|$MHS_METOP_B_COV_STORE
OBS_MHS_METOP_C|mhs_metop-c|$MHS_METOP_C_BIAS_OUT|$MHS_METOP_C_COV_OUT|$MHS_METOP_C_BIAS_STORE|$MHS_METOP_C_COV_STORE
OBS_IASI_METOP_B|iasi_metop-b|$IASI_METOP_B_BIAS_OUT|$IASI_METOP_B_COV_OUT|$IASI_METOP_B_BIAS_STORE|$IASI_METOP_B_COV_STORE
EOF

  # The variational run writes diagnostic analysis files throughout the window.
  # Merge only the analyzed fields from the middle-window diagnostic into a
  # complete copy of the native middle-window restart.
  require_file "$AN_GUESS_FILE"
  require_file "$JEDI_MID_ANALYSIS_FILE"
  [ -s "$AN_GUESS_FILE" ] || die "middle-window guess is empty: $AN_GUESS_FILE"
  [ -s "$JEDI_MID_ANALYSIS_FILE" ] || die "middle-window JEDI analysis is empty: $JEDI_MID_ANALYSIS_FILE"

  if [ ! -d "$DCP_TMP_DIR" ]; then
    mkdir -p "$DCP_TMP_DIR"
    if command -v lfs >/dev/null 2>&1; then
      # New files created here inherit the tested 8-OST / 4-MiB layout.
      lfs setstripe -c 8 -S 4M "$DCP_TMP_DIR" || \
        log "WARNING: could not set Lustre striping on $DCP_TMP_DIR"
    fi
  fi

  AN_ANALYSIS_TMP="$DCP_TMP_DIR/$(basename "$AN_ANALYSIS_FILE").tmp.${SLURM_JOB_ID:-$$}"
  rm -f "$AN_ANALYSIS_TMP"

  log "Parallel-copying middle-window guess with dcp"
  log "dcp source=$AN_GUESS_FILE"
  log "dcp target=$AN_ANALYSIS_TMP"
  log "dcp layout: nodes=$DCP_NODES ranks=$DCP_NTASKS tasks/node=$DCP_TASKS_PER_NODE"

  set +e
  srun -N "$DCP_NODES" -n "$DCP_NTASKS" \
    --ntasks-per-node="$DCP_TASKS_PER_NODE" \
    --cpus-per-task=1 \
    --cpu-bind=cores \
    dcp \
      --bufsize "$DCP_BUFSIZE" \
      --chunksize "$DCP_CHUNKSIZE" \
      --progress "$DCP_PROGRESS" \
      "$AN_GUESS_FILE" \
      "$AN_ANALYSIS_TMP"
  dcp_rc=$?
  set -e

  [ "$dcp_rc" -eq 0 ] || die "dcp failed with rc=$dcp_rc"
  [ -s "$AN_ANALYSIS_TMP" ] || die "dcp did not create a nonempty file: $AN_ANALYSIS_TMP"

  src_size="$(stat -c %s "$AN_GUESS_FILE")"
  dst_size="$(stat -c %s "$AN_ANALYSIS_TMP")"
  [ "$src_size" -eq "$dst_size" ] || \
    die "dcp size mismatch: source=$src_size destination=$dst_size"

  log "Overwriting analyzed fields from $JEDI_MID_ANALYSIS_FILE"
  set +e
  ncks -A -v "$JEDI_ANALYSIS_VARS" \
    "$JEDI_MID_ANALYSIS_FILE" \
    "$AN_ANALYSIS_TMP"
  ncks_rc=$?
  set -e

  [ "$ncks_rc" -eq 0 ] || die "ncks field merge failed with rc=$ncks_rc"
  [ -s "$AN_ANALYSIS_TMP" ] || die "merged analysis is empty: $AN_ANALYSIS_TMP"

  rm -f "$AN_ANALYSIS_FILE"
  mv -f "$AN_ANALYSIS_TMP" "$AN_ANALYSIS_FILE"
  require_file "$AN_ANALYSIS_FILE"
  log "Final forecast analysis created: $AN_ANALYSIS_FILE"
fi

exit "$rc"
