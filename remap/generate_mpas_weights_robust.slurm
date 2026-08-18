#!/bin/bash
#SBATCH --job-name=MPAS.WEIGHTS
#SBATCH --partition=opr
#SBATCH --nodes=8
#SBATCH --ntasks=8
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_remap/weights/robust.%j.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_remap/weights/robust.%j.out
#SBATCH --export=ALL

set -x
ROOT=/scratch/lus/arw/jedi/mpas_remap
GRID="$ROOT/grids"
WGT="$ROOT/weights"
VAL="$ROOT/tools/validate_esmf_weights.py"
mkdir -p "$WGT"
module load esmf/8.8.0-intel-oneapi-compilers-2024.2.0-nkqudbm
unset OMP_STACKSIZE
export OMP_NUM_THREADS=1
export MPICH_RANK_REORDER_METHOD=0
FAILED=0

validate_weight() {
  OUT="$1"; SRC="$2"; DST="$3"
  python "$VAL" "$OUT" "$SRC" "$DST"
  RC=$?
  if [ "$RC" -ne 0 ]; then echo "FAILED VALIDATION: $OUT rc=$RC"; return 1; fi
  echo "VALIDATED: $OUT"; return 0
}

generate_one() {
  SRC="$1"; DST="$2"; OUT="$3"
  echo "============================================================"
  echo "SOURCE      : $SRC"; echo "DESTINATION : $DST"; echo "OUTPUT      : $OUT"
  echo "============================================================"
  if [ -s "$OUT" ]; then
    validate_weight "$OUT" "$SRC" "$DST"
    RC=$?
    if [ "$RC" -eq 0 ]; then echo "REUSE: existing validated weight file"; return 0; fi
    echo "Existing file invalid; removing before regeneration"; rm -f "$OUT"
  fi
  srun --exclusive -N 8 -n 8 --ntasks-per-node=1 --cpus-per-task=1 --cpu-bind=cores \
    ESMF_RegridWeightGen \
    -s "$SRC" -d "$DST" -m conserve \
    --src_type SCRIP --dst_type SCRIP \
    --line_type greatcircle --norm_type dstarea --user_areas \
    --netcdf4 --weight_only -w "$OUT"
  RC=$?
  if [ "$RC" -ne 0 ]; then echo "FAILED GENERATION: rc=$RC : $OUT"; rm -f "$OUT"; return 1; fi
  if [ ! -s "$OUT" ]; then echo "FAILED GENERATION: output missing/empty: $OUT"; return 1; fi
  sync
  validate_weight "$OUT" "$SRC" "$DST"
  RC=$?
  if [ "$RC" -ne 0 ]; then echo "FAILED VALIDATION AFTER GENERATION: $OUT"; rm -f "$OUT"; return 1; fi
  ls -lh "$OUT"; return 0
}

generate_one "$GRID/x1.4096002.scrip.nc" "$GRID/x1.1024002.scrip.nc" "$WGT/x1.4096002_to_x1.1024002.conserve.nc" || FAILED=1
generate_one "$GRID/x1.1024002.scrip.nc" "$GRID/x1.4096002.scrip.nc" "$WGT/x1.1024002_to_x1.4096002.conserve.nc" || FAILED=1
generate_one "$GRID/x1.4096002.scrip.nc" "$GRID/x1.655362.scrip.nc" "$WGT/x1.4096002_to_x1.655362.conserve.nc" || FAILED=1
generate_one "$GRID/x1.655362.scrip.nc" "$GRID/x1.4096002.scrip.nc" "$WGT/x1.655362_to_x1.4096002.conserve.nc" || FAILED=1

echo "============================================================"; echo "FINAL STATUS"; echo "============================================================"
ls -lh "$WGT"/*.conserve.nc 2>/dev/null
if [ "$FAILED" -ne 0 ]; then echo "FAILED: one or more matrices were not generated and validated"; false
else echo "SUCCESS: all conservative matrices generated and independently validated"; true
fi
