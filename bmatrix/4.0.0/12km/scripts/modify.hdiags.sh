#!/bin/bash
#
# Merge and tune MPAS-JEDI HDIAGS products following the NCAR workflow.
#
# No ncap2 is required.
#
# Requirements:
#   - ncks
#   - Python 3
#   - numpy
#   - netCDF4
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE="${BASE:-$HOME/jedi/mpas_only/4.0.0/HDIAGS}"

VARGROUP1="${BASE}/vargroup1"
VARGROUP2="${BASE}/vargroup2"
MERGEDIR="${BASE}/merge"

INCLUDE_HYDROMETEORS="${INCLUDE_HYDROMETEORS:-1}"
TUNE_CORRELATION_LENGTHS="${TUNE_CORRELATION_LENGTHS:-1}"
TUNE_STANDARD_DEVIATIONS="${TUNE_STANDARD_DEVIATIONS:-1}"

CORRELATION_DIVISOR="${CORRELATION_DIVISOR:-2.0}"
STDDEV_DIVISOR="${STDDEV_DIVISOR:-3.0}"

HYDRO_VARS="qc,qi,qr,qs,qg"

FILE_RH="mpas.cor_rh.nc"
FILE_RV="mpas.cor_rv.nc"
FILE_SD="mpas.stddev.nc"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

log()
{
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die()
{
    log "ERROR: $*"
    exit 1
}

backup_file()
{
    local file="$1"

    if [[ -f "$file" ]]; then
        cp -p "$file" "${file}.bak.${STAMP}"
        log "Backup created: ${file}.bak.${STAMP}"
    fi
}

check_command()
{
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

check_python_modules()
{
    python3 - <<'PY'
import sys

try:
    import numpy
    import netCDF4
except Exception as exc:
    print(f"ERROR: Python dependency unavailable: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

check_input_file()
{
    local file="$1"
    [[ -s "$file" ]] || die "Missing or empty input file: $file"
}

# ---------------------------------------------------------------------------
# Requirements
# ---------------------------------------------------------------------------

check_command ncks
check_command python3
check_python_modules

check_input_file "${VARGROUP1}/${FILE_RH}"
check_input_file "${VARGROUP1}/${FILE_RV}"
check_input_file "${VARGROUP1}/${FILE_SD}"

if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
    check_input_file "${VARGROUP2}/${FILE_RH}"
    check_input_file "${VARGROUP2}/${FILE_RV}"
    check_input_file "${VARGROUP2}/${FILE_SD}"
fi

# ---------------------------------------------------------------------------
# Prepare merge directory
# ---------------------------------------------------------------------------

mkdir -p "${MERGEDIR}"

for file in "${FILE_RH}" "${FILE_RV}" "${FILE_SD}"; do
    if [[ -f "${MERGEDIR}/${file}" ]]; then
        backup_file "${MERGEDIR}/${file}"
    fi
done

log "Copying vargroup1 files into ${MERGEDIR}"

cp -p "${VARGROUP1}/${FILE_RH}" "${MERGEDIR}/${FILE_RH}"
cp -p "${VARGROUP1}/${FILE_RV}" "${MERGEDIR}/${FILE_RV}"
cp -p "${VARGROUP1}/${FILE_SD}" "${MERGEDIR}/${FILE_SD}"

# ---------------------------------------------------------------------------
# Append hydrometeor fields
# ---------------------------------------------------------------------------

if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
    log "Appending hydrometeor variables: ${HYDRO_VARS}"

    ncks -A -v "${HYDRO_VARS}" \
        "${VARGROUP2}/${FILE_RH}" \
        "${MERGEDIR}/${FILE_RH}"

    ncks -A -v "${HYDRO_VARS}" \
        "${VARGROUP2}/${FILE_RV}" \
        "${MERGEDIR}/${FILE_RV}"

    ncks -A -v "${HYDRO_VARS}" \
        "${VARGROUP2}/${FILE_SD}" \
        "${MERGEDIR}/${FILE_SD}"
fi

# ---------------------------------------------------------------------------
# Apply NCAR-style modifications using Python/netCDF4
# ---------------------------------------------------------------------------

log "Applying NCAR-style HDIAGS modifications"

python3 - \
    "${MERGEDIR}/${FILE_RH}" \
    "${MERGEDIR}/${FILE_RV}" \
    "${MERGEDIR}/${FILE_SD}" \
    "${INCLUDE_HYDROMETEORS}" \
    "${TUNE_CORRELATION_LENGTHS}" \
    "${TUNE_STANDARD_DEVIATIONS}" \
    "${CORRELATION_DIVISOR}" \
    "${STDDEV_DIVISOR}" <<'PY'
import os
import shutil
import sys
from datetime import datetime, timezone

import numpy as np
from netCDF4 import Dataset


rh_file = sys.argv[1]
rv_file = sys.argv[2]
stddev_file = sys.argv[3]

include_hydrometeors = int(sys.argv[4]) == 1
tune_correlations = int(sys.argv[5]) == 1
tune_stddev = int(sys.argv[6]) == 1

correlation_divisor = float(sys.argv[7])
stddev_divisor = float(sys.argv[8])

hydrometeors = ["qc", "qi", "qr", "qs", "qg"]

control_variables = [
    "stream_function",
    "velocity_potential",
    "temperature",
    "spechum",
    "surface_pressure",
]

timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def log(message: str) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{now}] {message}", flush=True)


def backup(path: str, suffix: str) -> None:
    destination = f"{path}.{suffix}.{timestamp}"
    shutil.copy2(path, destination)
    log(f"Backup created: {destination}")


def ensure_variables(dataset: Dataset, variables: list[str], path: str) -> None:
    missing = [name for name in variables if name not in dataset.variables]
    if missing:
        raise RuntimeError(
            f"Missing variables in {path}: {', '.join(missing)}"
        )


def replace_nonpositive_with_zero(path: str, variables: list[str]) -> None:
    backup(path, "before_missing_cleanup")

    with Dataset(path, "r+") as dataset:
        ensure_variables(dataset, variables, path)

        for name in variables:
            variable = dataset.variables[name]
            data = variable[:]

            # Preserve masked values while replacing valid values <= 0.
            if np.ma.isMaskedArray(data):
                result = np.ma.array(data, copy=True)
                valid = ~np.ma.getmaskarray(result)
                result[(valid) & (result <= 0.0)] = 0.0
            else:
                result = np.array(data, copy=True)
                result[result <= 0.0] = 0.0

            variable[:] = result

            minimum = float(np.ma.min(result))
            maximum = float(np.ma.max(result))

            log(
                f"{os.path.basename(path)}: cleaned {name}; "
                f"range={minimum:.8e} to {maximum:.8e}"
            )


def divide_variables(
    path: str,
    variables: list[str],
    divisor: float,
    backup_suffix: str,
) -> None:
    if divisor == 0.0:
        raise ValueError(f"Invalid zero divisor for {path}")

    backup(path, backup_suffix)

    with Dataset(path, "r+") as dataset:
        ensure_variables(dataset, variables, path)

        for name in variables:
            variable = dataset.variables[name]
            data = variable[:]
            result = data / divisor
            variable[:] = result

            minimum = float(np.ma.min(result))
            maximum = float(np.ma.max(result))

            log(
                f"{os.path.basename(path)}: divided {name} by {divisor:g}; "
                f"range={minimum:.8e} to {maximum:.8e}"
            )


if include_hydrometeors:
    log("Replacing nonpositive hydrometeor values with zero")

    replace_nonpositive_with_zero(rh_file, hydrometeors)
    replace_nonpositive_with_zero(rv_file, hydrometeors)
    replace_nonpositive_with_zero(stddev_file, hydrometeors)


if tune_correlations:
    log(
        "Reducing horizontal correlation lengths for "
        "stream_function and velocity_potential"
    )

    divide_variables(
        path=rh_file,
        variables=["stream_function", "velocity_potential"],
        divisor=correlation_divisor,
        backup_suffix="before_correlation_tuning",
    )


if tune_stddev:
    variables = list(control_variables)

    if include_hydrometeors:
        variables.extend(hydrometeors)

    log(
        "Reducing standard deviations for: "
        + ", ".join(variables)
    )

    divide_variables(
        path=stddev_file,
        variables=variables,
        divisor=stddev_divisor,
        backup_suffix="before_stddev_tuning",
    )


log("All NCAR-style modifications completed")
PY

# ---------------------------------------------------------------------------
# Validate output variables
# ---------------------------------------------------------------------------

log "Checking merged output files"

required_control_vars=(
    stream_function
    velocity_potential
    temperature
    spechum
    surface_pressure
)

required_hydro_vars=(
    qc
    qi
    qr
    qs
    qg
)

for file in "${FILE_RH}" "${FILE_RV}" "${FILE_SD}"; do
    path="${MERGEDIR}/${file}"

    [[ -s "${path}" ]] || die "Output file missing or empty: ${path}"

    for var in "${required_control_vars[@]}"; do
        ncks -m -v "${var}" "${path}" >/dev/null 2>&1 ||
            die "${var} is missing from ${path}"
    done

    if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
        for var in "${required_hydro_vars[@]}"; do
            ncks -m -v "${var}" "${path}" >/dev/null 2>&1 ||
                die "${var} is missing from ${path}"
        done
    fi
done

log "Resulting files:"
ls -lh \
    "${MERGEDIR}/${FILE_RH}" \
    "${MERGEDIR}/${FILE_RV}" \
    "${MERGEDIR}/${FILE_SD}"

log "Processing completed successfully"
