#!/bin/bash
#SBATCH --job-name=nmcprep_main
#SBATCH --partition=opr,workq
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=02:00:00
#SBATCH --output=logs/prep.%j.out
#SBATCH --error=logs/prep.%j.err

# ==============================================================================
# MPAS-JEDI / SABER-BUMP NMC sample preprocessing driver
# ------------------------------------------------------------------------------
# This is a single self-contained Slurm script for the preprocessing part only.
# It replaces the individual wrappers:
#   prep_1_make_native_mpas_init_links.bash
#   prep_2_generate_template_PTB.bash
#   prep_3_convert_uv_to_psichi_f24.bash
#   prep_3_convert_uv_to_psichi_f48.bash
#   prep_4_add_variables_f24.bash
#   prep_4_add_variables_f48.bash
#   prep_5_ncdiff.bash
# and inlines their working logic.
#
# It DOES NOT replace vbal.sh, hdiags.sh, nicas.sh, or merge.sh.
#
# Output location is controlled by ROOT and is independent of the
# MPAS-JEDI/SABER release used later for B-matrix calibration.
#
# Shared scientific tools/weights are read from the same parent paths used by
# the operational convert/add/diff scripts:
#   ${HOME}/jedi/mpas_only/tools
#   ${HOME}/jedi/mpas_only/weights
#
# Usage:
#   ./prepare_nmc_samples.sh          # self-submits to Slurm
# or:
#   sbatch prepare_nmc_samples.sh
# ==============================================================================

set -x

# ------------------------------------------------------------------------------
# Location of the scripts distributed with this repository.
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Self-submit when launched interactively.
# ------------------------------------------------------------------------------
if [ -z "${SLURM_JOB_ID:-}" ] && [ "${1:-}" = "" ]; then
  mkdir -p logs
  jid=$(sbatch --parsable "$0")
  echo "Submitted preprocessing main job: ${jid}"
  exit 0
fi

# ------------------------------------------------------------------------------
# User-adjustable settings.
# ------------------------------------------------------------------------------
# Working directory for generated NMC products.
# Keep this outside the Git repository: FULL/PTB NetCDF files are very large.
ROOT="${NMC_ROOT:-${HOME}/jedi/nmc_samples}"

# Shared scientific utilities/resources.
PARENT_ROOT="${MPAS_JEDI_TOOLS_ROOT:-${HOME}/jedi/mpas_only}"
SRC_NMC="${SRC_NMC:-${D:-/scratch/lus/tmp/arw/day}/nmc}"
TOOLS_DIR="${TOOLS_DIR:-${PARENT_ROOT}/tools}"
WEIGHTS_DIR="${WEIGHTS_DIR:-${PARENT_ROOT}/weights}"
LATLON_PREFIX="${LATLON_PREFIX:-latlon_0p1}"

# Forecast leads available in the native MPAS archive.
#
# Historical experiment used:
#   actual +12 h forecast -> technical F24 label
#   actual +24 h forecast -> technical F48 label
#
# The labels F24/F48 are retained because they are part of the established
# downstream FULL_f24/FULL_f48/PTB_f48mf24 naming convention.
#
# For a conventional true F24/F48 NMC experiment, run with:
#   NMC_SHORT_LEAD=24 NMC_LONG_LEAD=48 ./prepare_nmc_samples.sh
NMC_SHORT_LEAD="${NMC_SHORT_LEAD:-12}"
NMC_LONG_LEAD="${NMC_LONG_LEAD:-24}"

# Keep everything produced by this version under ${ROOT}
INPUT_DIR="${ROOT}/input/native_mpas_INIT_links"
LIST_DIR="${ROOT}/lists"
LOG_DIR="${ROOT}/logs"
TEMPLATE_DIR="${ROOT}/templates"
OUTROOT="${ROOT}/output"
SAMPLES_DIR="${ROOT}/samples"
WORK_ADDVAR="${ROOT}/work_addvar"   # legacy compatibility; active scratch is under Slurm TMPDIR

# Slurm resources for internal array stages.
# Each array task uses Slurm TMPDIR only for scratch/intermediate files.
# Final NetCDF products are written directly in ${OUTROOT}/YYYYMMDDHH/.
ARRAY_PARTITION="${ARRAY_PARTITION:-opr,workq}"
CONVERT_CPUS="${CONVERT_CPUS:-64}"
ADDVAR_CPUS="${ADDVAR_CPUS:-32}"
NCDIFF_CPUS="${NCDIFF_CPUS:-32}"
CONVERT_THROTTLE="${CONVERT_THROTTLE:-16}"
ADDVAR_THROTTLE="${ADDVAR_THROTTLE:-8}"
NCDIFF_THROTTLE="${NCDIFF_THROTTLE:-8}"

# Set to 1 for a fresh B-matrix preprocessing run.
CLEAN_OUTPUT="${CLEAN_OUTPUT:-1}"

# Optional date filter on cycle directory YYYYMMDDHH via START_CYCLE/END_CYCLE.
START_CYCLE="${START_CYCLE:-0000000000}"
END_CYCLE="${END_CYCLE:-9999999999}"

SELF="$0"

# ------------------------------------------------------------------------------
# Utility functions.
# ------------------------------------------------------------------------------
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*"; }
fatal() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

require_file() { [ -s "$1" ] || fatal "missing file: $1"; }
require_dir() { [ -d "$1" ] || fatal "missing directory: $1"; }

make_stage_tmpdir() {
  # Use Slurm-provided TMPDIR when available. The fallback is only for manual testing
  # outside Slurm; production array jobs should always have TMPDIR.
  local label="$1"
  local base="${TMPDIR:-/tmp/${USER:-user}/mpas_nmc_${SLURM_JOB_ID:-manual}}"
  local d="${base}/${label}_${SLURM_ARRAY_JOB_ID:-0}_${SLURM_ARRAY_TASK_ID:-0}"
  mkdir -p "${d}"
  echo "${d}"
}

var_exists() {
  local f="$1" v="$2"
  python3 - "$f" "$v" <<'PYV'
import sys
from netCDF4 import Dataset
f, v = sys.argv[1], sys.argv[2]
with Dataset(f, 'r') as ds:
    sys.exit(0 if v in ds.variables else 1)
PYV
}

load_runtime() {
  # GNU Spack-stack 1.9.3 runtime.
# Site-specific software environment.
#
# Set NMC_ENV_SCRIPT to the shell initialization script providing the
# MPAS-JEDI/NCO/Python runtime required by this workflow.
#
# Example used for the original experiment:
#   export NMC_ENV_SCRIPT=/scratch/lus/arw/spack-stack-1.9.3-gnu/switch_to_gnu.sh
NMC_ENV_SCRIPT="${NMC_ENV_SCRIPT:-/scratch/lus/arw/spack-stack-1.9.3-gnu/switch_to_gnu.sh}"

if [ -f "${NMC_ENV_SCRIPT}" ]; then
  source "${NMC_ENV_SCRIPT}"
else
  log "WARNING: NMC_ENV_SCRIPT not found: ${NMC_ENV_SCRIPT}"
  log "Assuming the required software environment is already loaded."
fi

source "${SCRIPT_DIR}/common_runtime.sh"
}

check_runtime() {
  command -v python3 >/dev/null 2>&1 || fatal "python3 not found"
  command -v ncks    >/dev/null 2>&1 || fatal "ncks not found"
  command -v ncrename >/dev/null 2>&1 || fatal "ncrename not found"
  command -v ncatted >/dev/null 2>&1 || fatal "ncatted not found"
  command -v ncdiff  >/dev/null 2>&1 || fatal "ncdiff not found"
  python3 - <<'PY' || fatal "Python modules netCDF4 and/or numpy are unavailable"
import netCDF4, numpy
PY
}

# ------------------------------------------------------------------------------
# Stage 1: detect native MPAS NMC files and create INIT links.
#
# NMC_SHORT_LEAD and NMC_LONG_LEAD define the actual forecast leads selected
# from the native MPAS archive.
#
# The historical experiment used:
#   NMC_SHORT_LEAD=12  -> technical F24
#   NMC_LONG_LEAD=24   -> technical F48
#
# The technical F24/F48 labels are retained for compatibility with the
# established downstream filenames:
#   FULL_f24.nc
#   FULL_f48.nc
#   PTB_f48mf24.nc
#
# For a conventional true +24 h / +48 h NMC pair, set:
#   NMC_SHORT_LEAD=24
#   NMC_LONG_LEAD=48
# ------------------------------------------------------------------------------
make_native_links_and_pairs() {
  require_dir "${SRC_NMC}"
  mkdir -p "${INPUT_DIR}" "${LIST_DIR}" "${LOG_DIR}"

  rm -f "${LIST_DIR}"/*.txt
  : > "${LIST_DIR}/inventory.txt"
  : > "${LIST_DIR}/f24_files.txt"
  : > "${LIST_DIR}/f48_files.txt"

  log "Detecting native MPAS NMC files under ${SRC_NMC}"
  log "Cycle window: ${START_CYCLE} .. ${END_CYCLE}"

  find "${SRC_NMC}" -mindepth 2 -maxdepth 2 -type f -name 'MPAS.*.nc' | sort | while read -r f; do
    cycle=$(basename "$(dirname "$f")")
    [ "${cycle}" -lt "${START_CYCLE}" ] && continue
    [ "${cycle}" -gt "${END_CYCLE}" ] && continue

    base=$(basename "$f")
    valid=$(echo "$base" | sed -n 's/^MPAS\.\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{2\}\)\.nc$/\1/p')
    [ -z "${valid}" ] && continue

    cycepoch=$(date -u -d "${cycle:0:4}-${cycle:4:2}-${cycle:6:2} ${cycle:8:2}:00:00 UTC" +%s)
    valeph=$(date -u -d "${valid:0:10} ${valid:11:2}:00:00 UTC" +%s)
    lead=$(( (valeph - cycepoch) / 3600 ))

    y=${valid:0:4}; m=${valid:5:2}; d=${valid:8:2}; h=${valid:11:2}
    outdir="${INPUT_DIR}/${y}/${m}/${d}/r${h}"
    mkdir -p "${outdir}"

    if [ "${lead}" -eq "${NMC_SHORT_LEAD}" ]; then
      link="${outdir}/INIT.${valid}.F24.nc"
      ln -sfn "${f}" "${link}"
      echo "${link}" >> "${LIST_DIR}/f24_files_all.txt"
      echo "${cycle} realF${NMC_SHORT_LEAD} technicalF24 valid=${valid} source=${f} link=${link}" >> "${LIST_DIR}/inventory.txt"
    elif [ "${lead}" -eq "${NMC_LONG_LEAD}" ]; then
      link="${outdir}/INIT.${valid}.F48.nc"
      ln -sfn "${f}" "${link}"
      echo "${link}" >> "${LIST_DIR}/f48_files_all.txt"
      echo "${cycle} realF${NMC_LONG_LEAD} technicalF48 valid=${valid} source=${f} link=${link}" >> "${LIST_DIR}/inventory.txt"
    fi
  done

  sort -o "${LIST_DIR}/inventory.txt" "${LIST_DIR}/inventory.txt" 2>/dev/null || true
  sort -o "${LIST_DIR}/f24_files_all.txt" "${LIST_DIR}/f24_files_all.txt" 2>/dev/null || true
  sort -o "${LIST_DIR}/f48_files_all.txt" "${LIST_DIR}/f48_files_all.txt" 2>/dev/null || true

  [ -s "${LIST_DIR}/f24_files_all.txt" ] || fatal "no technical F24 files detected"
  [ -s "${LIST_DIR}/f48_files_all.txt" ] || fatal "no technical F48 files detected"

  # Match prep_3_convert_uv_to_psichi_f24/f48.bash exactly:
  # each convert wrapper lists every INIT.*.F24.nc and INIT.*.F48.nc independently.
  cp "${LIST_DIR}/f24_files_all.txt" "${LIST_DIR}/f24_files.txt"
  cp "${LIST_DIR}/f48_files_all.txt" "${LIST_DIR}/f48_files.txt"

  local n24 n48
  n24=$(wc -l < "${LIST_DIR}/f24_files.txt")
  n48=$(wc -l < "${LIST_DIR}/f48_files.txt")
  [ "${n24}" -gt 0 ] || fatal "no technical F24 files detected"
  [ "${n48}" -gt 0 ] || fatal "no technical F48 files detected"

  log "Detected technical files exactly as convert wrappers will process: F24=${n24}, F48=${n48}"
  log "First F24 entries:"; head -5 "${LIST_DIR}/f24_files.txt" || true
  log "First F48 entries:"; head -5 "${LIST_DIR}/f48_files.txt" || true
  log "Last F24 entries:"; tail -5 "${LIST_DIR}/f24_files.txt" || true
  log "Last F48 entries:"; tail -5 "${LIST_DIR}/f48_files.txt" || true
}

# ------------------------------------------------------------------------------
# Stage 2: create template_PTB.nc following the working old script exactly.
# The template contains zero-filled control variables created from theta:
#   stream_function, velocity_potential, temperature, spechum
# and native variables appended from the reference:
#   uReconstructZonal, uReconstructMeridional, relhum, surface_pressure, qc qi qr qs qg if present
# ------------------------------------------------------------------------------
make_template() {
  mkdir -p "${TEMPLATE_DIR}"
  local src f_tmp f_ref f_single f_work

  src=$(head -1 "${LIST_DIR}/f48_files.txt")
  require_file "${src}"

  f_ref="${ROOT}/MPAS_x1.4096002.nc"
  f_tmp="${TEMPLATE_DIR}/template_PTB.nc"
  f_single="${f_tmp}_single"
  f_work="${f_tmp}_work"

  log "Regenerating ${f_tmp}"
  log "Template source: ${src}"

  ln -sfn "${src}" "${f_ref}"
  rm -f "${f_tmp}" "${f_single}" "${f_work}"

  ncks -O -v theta "${f_ref}" "${f_single}"

  python3 - << PY
from netCDF4 import Dataset
import numpy as np
fn = "${f_single}"
with Dataset(fn, "a") as ds:
    if "theta" not in ds.variables:
        raise SystemExit("FATAL: theta not found in " + fn)
    v = ds.variables["theta"]
    v[:] = np.zeros(v.shape, dtype=v[:].dtype)
PY

  cp "${f_single}" "${f_work}"
  ncrename -O -v theta,stream_function "${f_work}"
  ncatted -O -a long_name,stream_function,o,c,"stream function" "${f_work}"
  ncatted -O -a units,stream_function,o,c,"m s^{-1}" "${f_work}"
  ncks -O -v stream_function "${f_work}" "${f_tmp}"

  cp "${f_single}" "${f_work}"
  ncrename -O -v theta,velocity_potential "${f_work}"
  ncatted -O -a long_name,velocity_potential,o,c,"velocity potential" "${f_work}"
  ncatted -O -a units,velocity_potential,o,c,"m s^{-1}" "${f_work}"
  ncks -A -v velocity_potential "${f_work}" "${f_tmp}"

  cp "${f_single}" "${f_work}"
  ncrename -O -v theta,temperature "${f_work}"
  ncatted -O -a long_name,temperature,o,c,"temperature" "${f_work}"
  ncatted -O -a units,temperature,o,c,"K" "${f_work}"
  ncks -A -v temperature "${f_work}" "${f_tmp}"

  cp "${f_single}" "${f_work}"
  ncrename -O -v theta,spechum "${f_work}"
  ncatted -O -a long_name,spechum,o,c,"specific humidity" "${f_work}"
  ncatted -O -a units,spechum,o,c,"kg kg^{-1}" "${f_work}"
  ncks -A -v spechum "${f_work}" "${f_tmp}"

  # Required native variables from reference file.
  for v in uReconstructZonal uReconstructMeridional relhum surface_pressure; do
    if var_exists "${f_ref}" "${v}"; then
      ncks -A -v "${v}" "${f_ref}" "${f_tmp}"
    else
      fatal "required template source variable ${v} not found in ${f_ref}"
    fi
  done

  # Hydrometeors, if present, exactly as in old working script.
  for v in qc qi qr qs qg; do
    if var_exists "${f_ref}" "${v}"; then
      ncks -A -v "${v}" "${f_ref}" "${f_tmp}"
    else
      log "WARNING: ${v} not found in ${f_ref}; skipping"
    fi
  done

  for v in stream_function velocity_potential temperature spechum surface_pressure uReconstructZonal uReconstructMeridional relhum; do
    var_exists "${f_tmp}" "${v}" || fatal "template is missing required variable: ${v}"
  done

  log "Created template: ${f_tmp}"
  ncks -m "${f_tmp}" | grep -E "stream_function|velocity_potential|temperature|spechum|surface_pressure|uReconstructZonal|uReconstructMeridional|relhum|qc|qi|qr|qs|qg" || true

  rm -f "${f_ref}" "${f_single}" "${f_work}"
}

# ------------------------------------------------------------------------------
# Submit and monitor Slurm array stages.
# ------------------------------------------------------------------------------
submit_array() {
  local label="$1" mode="$2" n="$3" throttle="$4" cpus="$5" tlim="$6"
  local jid
  log "Submitting ${label}: mode=${mode}, array=1-${n}%${throttle}, cpus=${cpus}" >&2
  jid=$(sbatch --parsable \
    --partition="${ARRAY_PARTITION}" \
    --nodes=1 --ntasks=1 --cpus-per-task="${cpus}" --exclusive \
    --array="1-${n}%${throttle}" \
    --time="${tlim}" \
    --job-name="nmcprep_${label}" \
    --output="${LOG_DIR}/${label}.%A_%a.out" \
    --error="${LOG_DIR}/${label}.%A_%a.err" \
    "${SELF}" "${mode}")
  echo "${jid}"
}

wait_job() {
  local label="$1" jid="$2"
  log "Waiting for ${label}: Slurm job ${jid}"
  while squeue -h -j "${jid}" >/dev/null 2>&1 && [ -n "$(squeue -h -j "${jid}" 2>/dev/null)" ]; do
    sleep 30
  done

  local states
  states=$(sacct -n -j "${jid}" --format=State -P 2>/dev/null | cut -d'|' -f1 | sed 's/+$//' | sort -u | tr '\n' ' ' || true)
  log "${label} states: ${states:-unknown}"
  echo "${states}" | grep -Eq 'FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|BOOT_FAIL|DEADLINE' && fatal "${label} failed: ${states}"
  echo "${states}" | grep -q 'COMPLETED' || fatal "${label} did not report COMPLETED: ${states}"
}

# ------------------------------------------------------------------------------
# Internal array stage: convert native MPAS u/v to psi/chi FULL_f24/FULL_f48.
# This follows scr/3_convert_uv_to_psichi_f24/f48.bash.
# ------------------------------------------------------------------------------
stage_convert_one() {
  load_runtime
  check_runtime
  local fhr="$1" list input_file bname valid_part vdate final_out outdir tmpdir
  export OMP_NUM_THREADS=1
  export OPENBLAS_NUM_THREADS=1
  export MKL_NUM_THREADS=1
  export NUMEXPR_NUM_THREADS=1

  if [ "${fhr}" = "24" ]; then list="${LIST_DIR}/f24_files.txt"; else list="${LIST_DIR}/f48_files.txt"; fi
  input_file=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "${list}")

  log "Convert F${fhr} task ${SLURM_ARRAY_TASK_ID} input=${input_file}"
  require_file "${input_file}"
  require_file "${TEMPLATE_DIR}/template_PTB.nc"
  require_dir "${WEIGHTS_DIR}"
  require_file "${TOOLS_DIR}/fast_3_convert_one.py"

  bname=$(basename "${input_file}")

  # Robust parser:
  # INIT.2026-05-23_00.F24.nc -> valid_part=2026-05-23_00 -> vdate=2026052300
  valid_part="${bname#INIT.}"
  valid_part="${valid_part%.F${fhr}.nc}"

  if [ "${valid_part}" = "${bname}" ] || [ -z "${valid_part}" ]; then
    fatal "could not parse valid time from ${bname}"
  fi

  vdate="${valid_part//-/}"
  vdate="${vdate//_/}"
  outdir="${OUTROOT}/${vdate}"
  final_out="${outdir}/FULL_f${fhr}.nc"

  tmpdir=$(make_stage_tmpdir "convert_f${fhr}")
  mkdir -p "${outdir}"
  rm -f "${final_out}"

  log "Using TMPDIR only for scratch: ${tmpdir}"
  log "Writing final convert output directly to: ${final_out}"
  TMPDIR="${tmpdir}" python3 "${TOOLS_DIR}/fast_3_convert_one.py" \
    --input "${input_file}" \
    --template "${TEMPLATE_DIR}/template_PTB.nc" \
    --output-root "${OUTROOT}" \
    --weights-dir "${WEIGHTS_DIR}" \
    --latlon-prefix "${LATLON_PREFIX}" \
    --fhr "${fhr}" \
    --workers "${SLURM_CPUS_PER_TASK}"

  require_file "${final_out}"
  for v in stream_function velocity_potential temperature spechum surface_pressure; do
    var_exists "${final_out}" "${v}" || fatal "${final_out} missing ${v} after convert"
  done

  rm -rf "${tmpdir}"
  log "Created ${final_out}"
}

# ------------------------------------------------------------------------------
# Internal array stage: add/overwrite temperature, spechum, surface_pressure,
# uReconstruct*, relhum, and hydrometeors. This follows scr/4_add_variables_*.
# ------------------------------------------------------------------------------
stage_addvar_one() {
  load_runtime
  check_runtime
  local fhr="$1" full_list full_file final_full vdate yyyy mm dd hh mpas_file tmpdir tmp_thermo
  export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

  if [ "${fhr}" = "24" ]; then full_list="${LIST_DIR}/full_f24_files.txt"; else full_list="${LIST_DIR}/full_f48_files.txt"; fi
  final_full=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "${full_list}")
  require_file "${final_full}"

  vdate=$(basename "$(dirname "${final_full}")")
  yyyy=${vdate:0:4}; mm=${vdate:4:2}; dd=${vdate:6:2}; hh=${vdate:8:2}
  mpas_file=$(find "${INPUT_DIR}" \( -type f -o -type l \) -name "INIT.${yyyy}-${mm}-${dd}_${hh}.F${fhr}.nc" | sort | head -1)
  require_file "${mpas_file}"

  log "Add variables F${fhr} task ${SLURM_ARRAY_TASK_ID}: FULL=${final_full} MPAS=${mpas_file}"

  for v in theta qv surface_pressure uReconstructZonal uReconstructMeridional relhum; do
    var_exists "${mpas_file}" "${v}" || fatal "${mpas_file} missing required variable for addvar: ${v}"
  done

  tmpdir=$(make_stage_tmpdir "addvar_f${fhr}")
  log "Using TMPDIR only for addvar scratch: ${tmpdir}"
  log "Updating final FULL file directly in place: ${final_full}"
  tmp_thermo="${tmpdir}/thermo_f${fhr}_${vdate}.nc"
  rm -f "${tmp_thermo}"
  full_file="${final_full}"

  python3 - << PY
import numpy as np
from netCDF4 import Dataset

mpas_file = "${mpas_file}"
tmp_file = "${tmp_thermo}"
RD_OVER_CP = 2.0 / 7.0

def clean(a):
    a = np.ma.asarray(a)
    if np.ma.isMaskedArray(a):
        a = a.filled(np.nan)
    a = np.asarray(a, dtype=np.float32)
    a = np.where(np.abs(a) > 1.0e20, np.nan, a)
    if np.isnan(a).any():
        a = np.where(np.isnan(a), np.nanmean(a), a)
    return a.astype(np.float32)

with Dataset(mpas_file, "r") as src, Dataset(tmp_file, "w", format="NETCDF4_CLASSIC") as dst:
    for dname in ["Time", "nCells", "nVertLevels"]:
        dim = src.dimensions[dname]
        dst.createDimension(dname, None if dim.isunlimited() else len(dim))

    theta = src.variables["theta"]
    qv = src.variables["qv"]

    temp = dst.createVariable("temperature", "f4", theta.dimensions)
    sh = dst.createVariable("spechum", "f4", qv.dimensions)
    temp.units = "K"; temp.long_name = "temperature"
    sh.units = "kg kg-1"; sh.long_name = "specific humidity"

    use_pressure_base = False
    if "pressure" in src.variables:
        pressure = src.variables["pressure"]
    elif "pressure_p" in src.variables and "pressure_base" in src.variables:
        use_pressure_base = True
    else:
        raise RuntimeError("No pressure or pressure_p+pressure_base found")

    nlev = len(src.dimensions["nVertLevels"])
    for k0 in range(0, nlev, 2):
        k1 = min(k0 + 2, nlev)
        print(f"Thermo levels {k0+1}-{k1}/{nlev}", flush=True)
        th = clean(theta[0, :, k0:k1]).astype("f8")
        q = clean(qv[0, :, k0:k1]).astype("f8")
        if use_pressure_base:
            p = clean(src.variables["pressure_p"][0, :, k0:k1]).astype("f8") + clean(src.variables["pressure_base"][0, :, k0:k1]).astype("f8")
        else:
            p = clean(pressure[0, :, k0:k1]).astype("f8")
        temp[0, :, k0:k1] = (th * np.power(p / 100000.0, RD_OVER_CP)).astype("f4")
        sh[0, :, k0:k1] = (q / (1.0 + q)).astype("f4")

    sp_src = src.variables["surface_pressure"]
    sp = dst.createVariable("surface_pressure", "f4", sp_src.dimensions)
    for a in sp_src.ncattrs():
        try: sp.setncattr(a, sp_src.getncattr(a))
        except Exception: pass
    sp[:] = clean(sp_src[:])
print("WROTE", tmp_file)
PY

  ncks -O -x -v temperature,spechum,surface_pressure "${full_file}" "${full_file}.tmp" 2>/dev/null && mv "${full_file}.tmp" "${full_file}" || true
  rm -f "${full_file}.tmp"
  ncks -A -v temperature,spechum,surface_pressure "${tmp_thermo}" "${full_file}"

  ncks -O -x -v uReconstructZonal,uReconstructMeridional,relhum "${full_file}" "${full_file}.tmp" 2>/dev/null && mv "${full_file}.tmp" "${full_file}" || true
  rm -f "${full_file}.tmp"
  ncks -A -v uReconstructZonal,uReconstructMeridional,relhum "${mpas_file}" "${full_file}"

  hydros=""
  for v in qc qi qr qs qg; do
    if var_exists "${mpas_file}" "$v"; then hydros="${hydros},${v}"; fi
  done
  hydros="${hydros#,}"
  if [ -n "${hydros}" ]; then
    ncks -O -x -v "${hydros}" "${full_file}" "${full_file}.tmp" 2>/dev/null && mv "${full_file}.tmp" "${full_file}" || true
    rm -f "${full_file}.tmp"
    ncks -A -v "${hydros}" "${mpas_file}" "${full_file}"
  else
    log "WARNING: no hydrometeors found in ${mpas_file}; skipping"
  fi

  for v in stream_function velocity_potential temperature spechum surface_pressure uReconstructZonal uReconstructMeridional relhum; do
    var_exists "${full_file}" "${v}" || fatal "${full_file} missing ${v} after addvar"
  done

  rm -rf "${tmpdir}"
  log "Updated ${final_full}"
}

# ------------------------------------------------------------------------------
# Internal array stage: NMC difference FULL_f48 - FULL_f24.
# This follows scr/5_ncdiff.bash.
# ------------------------------------------------------------------------------
stage_ncdiff_one() {
  load_runtime
  check_runtime
  local pair_dir f24 f48 ptb tmpdir tmp_ptb
  export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
  export OPENBLAS_NUM_THREADS=1
  export MKL_NUM_THREADS=1

  pair_dir=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "${LIST_DIR}/full_pair_dirs.txt")
  [ -n "${pair_dir}" ] && [ -d "${pair_dir}" ] || fatal "invalid pair directory for task ${SLURM_ARRAY_TASK_ID}: ${pair_dir}"

  f24="${pair_dir}/FULL_f24.nc"
  f48="${pair_dir}/FULL_f48.nc"
  ptb="${pair_dir}/PTB_f48mf24.nc"
  require_file "${f24}"
  require_file "${f48}"

  tmpdir=$(make_stage_tmpdir "ncdiff")
  tmp_ptb="${ptb}.tmp.${SLURM_ARRAY_JOB_ID}_${SLURM_ARRAY_TASK_ID}"
  rm -f "${tmp_ptb}" "${ptb}"

  log "Using TMPDIR only for ncdiff scratch: ${tmpdir}"
  log "Writing final ncdiff product directly to: ${ptb}"
  TMPDIR="${tmpdir}" ncdiff -t "${SLURM_CPUS_PER_TASK:-32}" -O "${f48}" "${f24}" "${tmp_ptb}"
  mv -f "${tmp_ptb}" "${ptb}"

  require_file "${ptb}"
  for v in stream_function velocity_potential temperature spechum surface_pressure; do
    var_exists "${ptb}" "${v}" || fatal "${ptb} missing ${v} after ncdiff"
  done

  rm -rf "${tmpdir}"
  log "Created ${ptb}"
}

# ------------------------------------------------------------------------------
# Verification helpers for stage transitions.
# ------------------------------------------------------------------------------
count_files() { find "$1" -type f -name "$2" | wc -l; }

verify_full_outputs() {
  local label="$1" pattern="$2" expected="$3"
  local found
  found=$(count_files "${OUTROOT}" "${pattern}")
  log "${label}: expected ${expected}, found ${found} files matching ${pattern}"
  [ "${found}" -eq "${expected}" ] || fatal "${label}: output count mismatch"
}

build_full_lists_after_convert() {
  # Match prep_4_add_variables_f24/f48.bash exactly:
  # add-variable stages scan all FULL_f24.nc and FULL_f48.nc independently.
  find "${OUTROOT}" -type f -name 'FULL_f24.nc' | sort > "${LIST_DIR}/full_f24_files.txt"
  find "${OUTROOT}" -type f -name 'FULL_f48.nc' | sort > "${LIST_DIR}/full_f48_files.txt"
  local n24 n48
  n24=$(wc -l < "${LIST_DIR}/full_f24_files.txt")
  n48=$(wc -l < "${LIST_DIR}/full_f48_files.txt")
  [ "${n24}" -gt 0 ] || fatal "No FULL_f24.nc files found"
  [ "${n48}" -gt 0 ] || fatal "No FULL_f48.nc files found"
  log "Add-variable input lists: FULL_f24=${n24}, FULL_f48=${n48}"
}

build_pair_dirs_after_addvar() {
  # Match prep_5_ncdiff.bash exactly:
  # scan immediate output subdirectories and keep only dirs containing both FULL files.
  : > "${LIST_DIR}/full_pair_dirs.txt"
  find "${OUTROOT}" -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
    if [ -s "$d/FULL_f24.nc" ] && [ -s "$d/FULL_f48.nc" ]; then
      echo "$d" >> "${LIST_DIR}/full_pair_dirs.txt"
    fi
  done

  local n
  n=$(wc -l < "${LIST_DIR}/full_pair_dirs.txt")
  [ "${n}" -gt 0 ] || fatal "No FULL f24/f48 pairs found"
  log "Found ${n} FULL f24/f48 pair directories for ncdiff"
}

prune_unpaired_outputs() {
  # Final output must contain only complete YYYYMMDDHH directories:
  # FULL_f24.nc, FULL_f48.nc, and PTB_f48mf24.nc.
  local d keep_file
  keep_file="${LIST_DIR}/full_pair_dirs.txt"
  require_file "${keep_file}"
  find "${OUTROOT}" -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
    if grep -Fxq "${d}" "${keep_file}" && [ -s "${d}/FULL_f24.nc" ] && [ -s "${d}/FULL_f48.nc" ] && [ -s "${d}/PTB_f48mf24.nc" ]; then
      :
    else
      log "Removing incomplete/unpaired output directory: ${d}"
      rm -rf "${d}"
    fi
  done
}

collect_samples() {
  mkdir -p "${SAMPLES_DIR}"
  rm -f "${SAMPLES_DIR}"/PTB_f48mf24_*.nc
  local i=0 ptb out
  while read -r d; do
    ptb="${d}/PTB_f48mf24.nc"
    require_file "${ptb}"
    i=$((i+1))
    out="${SAMPLES_DIR}/PTB_f48mf24_$(printf '%03d' "${i}").nc"
    ln -sfn "${ptb}" "${out}"
  done < "${LIST_DIR}/full_pair_dirs.txt"

  local ns npair
  ns=$(find "${SAMPLES_DIR}" -type l -name 'PTB_f48mf24_*.nc' | wc -l)
  npair=$(wc -l < "${LIST_DIR}/full_pair_dirs.txt")
  [ "${ns}" -eq "${npair}" ] || fatal "sample count ${ns} != pair-directory count ${npair}"
  log "Created ${ns} sample links in ${SAMPLES_DIR}"
}

# ------------------------------------------------------------------------------
# Main orchestration.
# ------------------------------------------------------------------------------
main() {
  cd "${ROOT}" || fatal "cannot cd to ${ROOT}"
  mkdir -p "${LOG_DIR}" "${LIST_DIR}" "${TEMPLATE_DIR}" "${OUTROOT}" "${SAMPLES_DIR}" "${WORK_ADDVAR}"
  load_runtime
  check_runtime

  log "Starting MPAS-JEDI/SABER-BUMP NMC preprocessing"
  log "ROOT=${ROOT}"
  log "SRC_NMC=${SRC_NMC}"
  log "TOOLS_DIR=${TOOLS_DIR}"
  log "WEIGHTS_DIR=${WEIGHTS_DIR}"

  require_dir "${TOOLS_DIR}"
  require_file "${TOOLS_DIR}/fast_3_convert_one.py"
  require_dir "${WEIGHTS_DIR}"

  make_native_links_and_pairs

  if [ "${CLEAN_OUTPUT}" = "1" ]; then
    log "CLEAN_OUTPUT=1: removing previous output/samples products; final files will be rebuilt directly under ${OUTROOT}"
    rm -rf "${OUTROOT}" "${SAMPLES_DIR}" "${WORK_ADDVAR}"
    mkdir -p "${OUTROOT}" "${SAMPLES_DIR}" "${WORK_ADDVAR}"
  fi

  make_template

  local n24 n48 npair jid
  n24=$(wc -l < "${LIST_DIR}/f24_files.txt")
  n48=$(wc -l < "${LIST_DIR}/f48_files.txt")

  jid=$(submit_array "convert_f24" "__convert24" "${n24}" "${CONVERT_THROTTLE}" "${CONVERT_CPUS}" "24:00:00")
  wait_job "convert_f24" "${jid}"
  verify_full_outputs "F24 conversion" "FULL_f24.nc" "${n24}"

  jid=$(submit_array "convert_f48" "__convert48" "${n48}" "${CONVERT_THROTTLE}" "${CONVERT_CPUS}" "24:00:00")
  wait_job "convert_f48" "${jid}"
  verify_full_outputs "F48 conversion" "FULL_f48.nc" "${n48}"

  build_full_lists_after_convert
  n24=$(wc -l < "${LIST_DIR}/full_f24_files.txt")
  n48=$(wc -l < "${LIST_DIR}/full_f48_files.txt")

  jid=$(submit_array "addvar_f24" "__add24" "${n24}" "${ADDVAR_THROTTLE}" "${ADDVAR_CPUS}" "06:00:00")
  wait_job "addvar_f24" "${jid}"

  jid=$(submit_array "addvar_f48" "__add48" "${n48}" "${ADDVAR_THROTTLE}" "${ADDVAR_CPUS}" "06:00:00")
  wait_job "addvar_f48" "${jid}"

  build_pair_dirs_after_addvar
  npair=$(wc -l < "${LIST_DIR}/full_pair_dirs.txt")

  jid=$(submit_array "ncdiff" "__ncdiff" "${npair}" "${NCDIFF_THROTTLE}" "${NCDIFF_CPUS}" "04:00:00")
  wait_job "ncdiff" "${jid}"

  prune_unpaired_outputs
  build_pair_dirs_after_addvar
  collect_samples

  log "DONE preprocessing. Ready for vbal.sh"
  log "Samples: ${SAMPLES_DIR}"
  ls -lh "${SAMPLES_DIR}"/PTB_f48mf24_*.nc | head || true
  ls -lh "${SAMPLES_DIR}"/PTB_f48mf24_*.nc | tail || true
}

# ------------------------------------------------------------------------------
# Dispatch internal modes or main.
# ------------------------------------------------------------------------------
case "${1:-}" in
  __convert24) stage_convert_one 24 ;;
  __convert48) stage_convert_one 48 ;;
  __add24)     stage_addvar_one 24 ;;
  __add48)     stage_addvar_one 48 ;;
  __ncdiff)    stage_ncdiff_one ;;
  "")          main ;;
  *)           fatal "unknown mode: $1" ;;
esac
