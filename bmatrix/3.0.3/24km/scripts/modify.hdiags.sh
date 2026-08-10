#!/bin/bash

#===============================================================================
# Merge and optionally tune 24 km MPAS-JEDI HDIAGS products.
#
# Input:
#   HDIAGS/vargroup1/
#     mpas.cor_rh.nc
#     mpas.cor_rv.nc
#     mpas.stddev.nc
#
#   HDIAGS/vargroup2/
#     mpas.cor_rh.nc
#     mpas.cor_rv.nc
#     mpas.stddev.nc
#
# Output:
#   HDIAGS/merge/
#     mpas.cor_rh.nc
#     mpas.cor_rv.nc
#     mpas.stddev.nc
#
# The script:
#   1. Copies the control-variable products from vargroup1.
#   2. Appends hydrometeor fields from vargroup2.
#   3. Replaces invalid/nonpositive hydrometeor diagnostic values with zero.
#   4. Optionally reduces selected horizontal correlation lengths.
#   5. Optionally reduces standard deviations.
#   6. Validates dimensions, variables and finite values.
#
# No ncap2 is required.
#===============================================================================

set -u
set -o pipefail

log()
{
    printf '[%s] %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$*"
}

fatal()
{
    log "FATAL: $*"
    return 1
}

require_file()
{
    if [[ ! -s "$1" ]]; then
        fatal "missing or empty file: $1"
        return 1
    fi

    return 0
}

require_dir()
{
    if [[ ! -d "$1" ]]; then
        fatal "missing directory: $1"
        return 1
    fi

    return 0
}

require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        fatal "required command not found: $1"
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

backup_file()
{
    local FILE="$1"
    local STAMP="$2"

    if [[ -f "${FILE}" ]]; then
        cp -p \
            "${FILE}" \
            "${FILE}.bak.${STAMP}" || return 1

        log "Backup created: ${FILE}.bak.${STAMP}"
    fi

    return 0
}

main()
{
    local VERSION
    local ROOT
    local BASE

    local VARGROUP1
    local VARGROUP2
    local MERGEDIR

    local FILE_RH
    local FILE_RV
    local FILE_SD

    local INCLUDE_HYDROMETEORS
    local CLEAN_HYDROMETEORS
    local TUNE_CORRELATION_LENGTHS
    local TUNE_STANDARD_DEVIATIONS

    local CORRELATION_DIVISOR
    local STDDEV_DIVISOR

    local EXPECTED_GRID
    local EXPECTED_LEVELS

    local STAMP
    local FILE
    local PATHNAME
    local VARIABLE
    local NCELLS
    local NLEVELS_FILE
    local PYTHON_RC

    # Fixed workflow paths and processing controls.
    # Never inherit these values from the submitting shell environment.
    VERSION="3.0.3"
    ROOT="${HOME}/jedi/mpas_only/${VERSION}/24km"
    BASE="${ROOT}/HDIAGS"

    VARGROUP1="${BASE}/vargroup1"
    VARGROUP2="${BASE}/vargroup2"
    MERGEDIR="${BASE}/merge"

    FILE_RH="mpas.cor_rh.nc"
    FILE_RV="mpas.cor_rv.nc"
    FILE_SD="mpas.stddev.nc"

    INCLUDE_HYDROMETEORS=1
    CLEAN_HYDROMETEORS=1

    TUNE_CORRELATION_LENGTHS=1
    TUNE_STANDARD_DEVIATIONS=1

    CORRELATION_DIVISOR="2.0"
    STDDEV_DIVISOR="3.0"

    EXPECTED_GRID=1024002
    EXPECTED_LEVELS=56

    if [[ "${ROOT}" != \
        "/scratch/lus/arw/jedi/mpas_only/3.0.3/24km" ]]
    then
        fatal "unexpected fixed workflow root: ${ROOT}"
        return 1
    fi

    if [[ "${VARGROUP1}" != "${ROOT}/HDIAGS/vargroup1" ]]; then
        fatal "unexpected vargroup1 path: ${VARGROUP1}"
        return 1
    fi

    if [[ "${VARGROUP2}" != "${ROOT}/HDIAGS/vargroup2" ]]; then
        fatal "unexpected vargroup2 path: ${VARGROUP2}"
        return 1
    fi

    if [[ "${MERGEDIR}" != "${ROOT}/HDIAGS/merge" ]]; then
        fatal "unexpected merge directory: ${MERGEDIR}"
        return 1
    fi

    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

    #===========================================================================
    # Requirements
    #===========================================================================

    require_command ncks || return 1
    require_command ncdump || return 1
    require_command python3 || return 1

    python3 - <<'PY'
import sys

try:
    import numpy
    import netCDF4
except Exception as exc:
    print(
        f"FAILED: Python dependency unavailable: {exc}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

    PYTHON_RC=$?

    if [[ "${PYTHON_RC}" -ne 0 ]]; then
        fatal "Python numpy/netCDF4 validation failed"
        return 1
    fi

    require_dir "${VARGROUP1}" || return 1

    require_file "${VARGROUP1}/${FILE_RH}" || return 1
    require_file "${VARGROUP1}/${FILE_RV}" || return 1
    require_file "${VARGROUP1}/${FILE_SD}" || return 1

    if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
        require_dir "${VARGROUP2}" || return 1

        require_file "${VARGROUP2}/${FILE_RH}" || return 1
        require_file "${VARGROUP2}/${FILE_RV}" || return 1
        require_file "${VARGROUP2}/${FILE_SD}" || return 1
    fi

    #===========================================================================
    # Validate source dimensions
    #===========================================================================

    for FILE in "${FILE_RH}" "${FILE_RV}" "${FILE_SD}"
    do
        NCELLS=$(get_dimension "${VARGROUP1}/${FILE}" nCells)

        if [[ "${NCELLS:-unknown}" != "${EXPECTED_GRID}" ]]; then
            fatal \
                "${VARGROUP1}/${FILE} has nCells=${NCELLS:-unknown}; " \
                "expected ${EXPECTED_GRID}"
            return 1
        fi
    done

    if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
        for FILE in "${FILE_RH}" "${FILE_RV}" "${FILE_SD}"
        do
            NCELLS=$(get_dimension "${VARGROUP2}/${FILE}" nCells)

            if [[ "${NCELLS:-unknown}" != "${EXPECTED_GRID}" ]]; then
                fatal \
                    "${VARGROUP2}/${FILE} has nCells=${NCELLS:-unknown}; " \
                    "expected ${EXPECTED_GRID}"
                return 1
            fi
        done
    fi

    NLEVELS_FILE=$(
        get_dimension \
            "${VARGROUP1}/${FILE_SD}" \
            nVertLevels
    )

    if [[ -n "${NLEVELS_FILE}" ]] &&
       [[ "${NLEVELS_FILE}" != "${EXPECTED_LEVELS}" ]]; then
        fatal \
            "${VARGROUP1}/${FILE_SD} has nVertLevels=${NLEVELS_FILE}; " \
            "expected ${EXPECTED_LEVELS}"
        return 1
    fi

    log "============================================================"
    log "24 km HDIAGS merge configuration"
    log "============================================================"
    log "Root                       : ${ROOT}"
    log "Vargroup1                  : ${VARGROUP1}"
    log "Vargroup2                  : ${VARGROUP2}"
    log "Merge directory            : ${MERGEDIR}"
    log "Include hydrometeors       : ${INCLUDE_HYDROMETEORS}"
    log "Clean hydrometeors         : ${CLEAN_HYDROMETEORS}"
    log "Tune correlation lengths   : ${TUNE_CORRELATION_LENGTHS}"
    log "Correlation divisor        : ${CORRELATION_DIVISOR}"
    log "Tune standard deviations   : ${TUNE_STANDARD_DEVIATIONS}"
    log "STDDEV divisor             : ${STDDEV_DIVISOR}"
    log "Expected grid              : ${EXPECTED_GRID}"
    log "Expected levels            : ${EXPECTED_LEVELS}"
    log "============================================================"

    #===========================================================================
    # Prepare merge directory
    #===========================================================================

    # The script may create and overwrite files only in this exact directory.
    case "${MERGEDIR}" in
        "${ROOT}/HDIAGS/merge")
            ;;
        *)
            fatal "refusing unsafe merge directory: ${MERGEDIR}"
            return 1
            ;;
    esac

    if [[ "${MERGEDIR}" == "/" ]] ||
       [[ "${MERGEDIR}" == "/scratch" ]] ||
       [[ "${MERGEDIR}" == "/scratch/lus" ]] ||
       [[ "${MERGEDIR}" == "/scratch/lus/tmp" ]] ||
       [[ "${MERGEDIR}" == "${HOME}" ]]
    then
        fatal "refusing protected merge directory: ${MERGEDIR}"
        return 1
    fi

    mkdir -p "${MERGEDIR}" || {
        fatal "cannot create merge directory: ${MERGEDIR}"
        return 1
    }

    for FILE in "${FILE_RH}" "${FILE_RV}" "${FILE_SD}"
    do
        backup_file "${MERGEDIR}/${FILE}" "${STAMP}" || {
            fatal "failed to back up ${MERGEDIR}/${FILE}"
            return 1
        }
    done

    log "Copying vargroup1 products into ${MERGEDIR}"

    cp -p \
        "${VARGROUP1}/${FILE_RH}" \
        "${MERGEDIR}/${FILE_RH}" || {
        fatal "failed to copy ${FILE_RH}"
        return 1
    }

    cp -p \
        "${VARGROUP1}/${FILE_RV}" \
        "${MERGEDIR}/${FILE_RV}" || {
        fatal "failed to copy ${FILE_RV}"
        return 1
    }

    cp -p \
        "${VARGROUP1}/${FILE_SD}" \
        "${MERGEDIR}/${FILE_SD}" || {
        fatal "failed to copy ${FILE_SD}"
        return 1
    }

    #===========================================================================
    # Append hydrometeor diagnostics
    #===========================================================================

    if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
        log "Appending hydrometeor fields: qc,qi,qr,qs,qg"

        ncks -A -v qc,qi,qr,qs,qg \
            "${VARGROUP2}/${FILE_RH}" \
            "${MERGEDIR}/${FILE_RH}" || {
            fatal "failed to append hydrometeors to ${FILE_RH}"
            return 1
        }

        ncks -A -v qc,qi,qr,qs,qg \
            "${VARGROUP2}/${FILE_RV}" \
            "${MERGEDIR}/${FILE_RV}" || {
            fatal "failed to append hydrometeors to ${FILE_RV}"
            return 1
        }

        ncks -A -v qc,qi,qr,qs,qg \
            "${VARGROUP2}/${FILE_SD}" \
            "${MERGEDIR}/${FILE_SD}" || {
            fatal "failed to append hydrometeors to ${FILE_SD}"
            return 1
        }
    fi

    #===========================================================================
    # Modify and validate the NetCDF fields
    #===========================================================================

    python3 - \
        "${MERGEDIR}/${FILE_RH}" \
        "${MERGEDIR}/${FILE_RV}" \
        "${MERGEDIR}/${FILE_SD}" \
        "${INCLUDE_HYDROMETEORS}" \
        "${CLEAN_HYDROMETEORS}" \
        "${TUNE_CORRELATION_LENGTHS}" \
        "${TUNE_STANDARD_DEVIATIONS}" \
        "${CORRELATION_DIVISOR}" \
        "${STDDEV_DIVISOR}" \
        "${EXPECTED_GRID}" \
        "${EXPECTED_LEVELS}" \
        "${STAMP}" <<'PY'
from __future__ import annotations

import math
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
clean_hydrometeors = int(sys.argv[5]) == 1
tune_correlations = int(sys.argv[6]) == 1
tune_stddev = int(sys.argv[7]) == 1

correlation_divisor = float(sys.argv[8])
stddev_divisor = float(sys.argv[9])

expected_grid = int(sys.argv[10])
expected_levels = int(sys.argv[11])
timestamp = sys.argv[12]


hydrometeors = ["qc", "qi", "qr", "qs", "qg"]

control_variables = [
    "stream_function",
    "velocity_potential",
    "temperature",
    "spechum",
    "surface_pressure",
]


def log(message: str) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[{now}] {message}", flush=True)


def backup(path: str, suffix: str) -> None:
    destination = f"{path}.{suffix}.{timestamp}"
    shutil.copy2(path, destination)
    log(f"Backup created: {destination}")


def require_variables(
    dataset: Dataset,
    names: list[str],
    path: str,
) -> None:
    missing = [name for name in names if name not in dataset.variables]

    if missing:
        raise RuntimeError(
            f"Missing variables in {path}: {', '.join(missing)}"
        )


def validate_dimensions(path: str) -> None:
    with Dataset(path, "r") as dataset:
        if "nCells" not in dataset.dimensions:
            raise RuntimeError(f"nCells is missing from {path}")

        ncells = len(dataset.dimensions["nCells"])

        if ncells != expected_grid:
            raise RuntimeError(
                f"{path}: nCells={ncells}, expected {expected_grid}"
            )

        if "nVertLevels" in dataset.dimensions:
            nlevels = len(dataset.dimensions["nVertLevels"])

            if nlevels != expected_levels:
                raise RuntimeError(
                    f"{path}: nVertLevels={nlevels}, "
                    f"expected {expected_levels}"
                )


def valid_data(variable) -> np.ma.MaskedArray:
    data = variable[:]

    if np.ma.isMaskedArray(data):
        return np.ma.array(data, copy=True)

    return np.ma.array(np.asarray(data), mask=False, copy=True)


def check_finite(
    path: str,
    variables: list[str],
) -> None:
    with Dataset(path, "r") as dataset:
        require_variables(dataset, variables, path)

        for name in variables:
            data = valid_data(dataset.variables[name])
            values = data.compressed()

            if values.size == 0:
                raise RuntimeError(f"{path}:{name} contains no valid values")

            if not np.all(np.isfinite(values)):
                raise RuntimeError(
                    f"{path}:{name} contains NaN or infinity"
                )


def clean_nonpositive_hydrometeors(
    path: str,
) -> None:
    backup(path, "before_hydrometeor_cleanup")

    with Dataset(path, "r+") as dataset:
        require_variables(dataset, hydrometeors, path)

        for name in hydrometeors:
            variable = dataset.variables[name]
            data = valid_data(variable)

            mask = np.ma.getmaskarray(data)
            values = np.asarray(data.data)

            invalid = (~mask) & (
                (~np.isfinite(values)) |
                (values <= 0.0)
            )

            values[invalid] = 0.0

            result = np.ma.array(
                values,
                mask=mask,
                copy=False,
            )

            variable[:] = result

            compressed = result.compressed()

            minimum = float(np.min(compressed))
            maximum = float(np.max(compressed))
            replaced = int(np.count_nonzero(invalid))

            log(
                f"{os.path.basename(path)}:{name}: "
                f"replaced={replaced}, "
                f"range={minimum:.8e} to {maximum:.8e}"
            )


def divide_variables(
    path: str,
    variables: list[str],
    divisor: float,
    backup_suffix: str,
) -> None:
    if not math.isfinite(divisor) or divisor <= 0.0:
        raise ValueError(
            f"Invalid divisor {divisor!r} for {path}"
        )

    backup(path, backup_suffix)

    with Dataset(path, "r+") as dataset:
        require_variables(dataset, variables, path)

        for name in variables:
            variable = dataset.variables[name]
            data = valid_data(variable)

            result = data / divisor
            variable[:] = result

            compressed = result.compressed()

            if compressed.size == 0:
                raise RuntimeError(
                    f"{path}:{name} has no valid values after division"
                )

            if not np.all(np.isfinite(compressed)):
                raise RuntimeError(
                    f"{path}:{name} became non-finite after division"
                )

            minimum = float(np.min(compressed))
            maximum = float(np.max(compressed))

            log(
                f"{os.path.basename(path)}:{name}: "
                f"divided by {divisor:g}; "
                f"range={minimum:.8e} to {maximum:.8e}"
            )


for path in (rh_file, rv_file, stddev_file):
    validate_dimensions(path)


required_rh_rv = list(control_variables)
required_stddev = list(control_variables)

if include_hydrometeors:
    required_rh_rv.extend(hydrometeors)
    required_stddev.extend(hydrometeors)


check_finite(rh_file, required_rh_rv)
check_finite(rv_file, required_rh_rv)
check_finite(stddev_file, required_stddev)


if include_hydrometeors and clean_hydrometeors:
    log("Cleaning nonpositive or non-finite hydrometeor diagnostics")

    clean_nonpositive_hydrometeors(rh_file)
    clean_nonpositive_hydrometeors(rv_file)
    clean_nonpositive_hydrometeors(stddev_file)


if tune_correlations:
    log(
        "Reducing horizontal correlation lengths for "
        "stream_function and velocity_potential"
    )

    divide_variables(
        path=rh_file,
        variables=[
            "stream_function",
            "velocity_potential",
        ],
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


check_finite(rh_file, required_rh_rv)
check_finite(rv_file, required_rh_rv)
check_finite(stddev_file, required_stddev)

log("All HDIAGS merge and tuning operations completed")
PY

    PYTHON_RC=$?

    if [[ "${PYTHON_RC}" -ne 0 ]]; then
        fatal "Python HDIAGS modification failed"
        return 1
    fi

    #===========================================================================
    # Final shell-level validation
    #===========================================================================

    for FILE in "${FILE_RH}" "${FILE_RV}" "${FILE_SD}"
    do
        PATHNAME="${MERGEDIR}/${FILE}"

        require_file "${PATHNAME}" || return 1

        NCELLS=$(get_dimension "${PATHNAME}" nCells)

        if [[ "${NCELLS:-unknown}" != "${EXPECTED_GRID}" ]]; then
            fatal \
                "${PATHNAME} has nCells=${NCELLS:-unknown}; " \
                "expected ${EXPECTED_GRID}"
            return 1
        fi

        for VARIABLE in \
            stream_function \
            velocity_potential \
            temperature \
            spechum \
            surface_pressure
        do
            if ! ncks -m -v "${VARIABLE}" "${PATHNAME}" \
                >/dev/null 2>&1
            then
                fatal "${VARIABLE} is missing from ${PATHNAME}"
                return 1
            fi
        done

        if [[ "${INCLUDE_HYDROMETEORS}" -eq 1 ]]; then
            for VARIABLE in qc qi qr qs qg
            do
                if ! ncks -m -v "${VARIABLE}" "${PATHNAME}" \
                    >/dev/null 2>&1
                then
                    fatal "${VARIABLE} is missing from ${PATHNAME}"
                    return 1
                fi
            done
        fi
    done

    log "============================================================"
    log "Merged 24 km HDIAGS products"
    log "============================================================"

    ls -lh \
        "${MERGEDIR}/${FILE_RH}" \
        "${MERGEDIR}/${FILE_RV}" \
        "${MERGEDIR}/${FILE_SD}"

    log "Processing completed successfully"

    return 0
}

main "$@"
