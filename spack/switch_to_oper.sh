#!/bin/bash
# ==============================================================================
# switch_to_oper.sh
# Clean Intel oneAPI 2024.2 + HPE Cray operational MPAS-JEDI environment.
# Usage: source "$HOME/spack-stack-oper/switch_to_oper.sh"
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "ERROR: source this script instead of executing it:"
    echo "  source ${BASH_SOURCE[0]}"
    return 1
fi

_oper_log()  { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
_oper_fail() { printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

_oper_load()
{
    local name="$1"
    case ":${LOADEDMODULES:-}:" in
        *":${name}:"*) return 0 ;;
    esac
    _oper_log "Loading module: ${name}"
    module load "${name}"
}

_oper_prefix()
{
    local pattern="$1" entry
    while IFS= read -r entry; do
        [[ -d "$entry" && "$entry" == *"/${pattern}-"* ]] && {
            printf '%s\n' "$entry"
            return 0
        }
    done < <(tr ':' '\n' <<< "${CMAKE_PREFIX_PATH:-}")
    return 1
}

_oper_set_root()
{
    local variable="$1" package="$2" value
    value="$(_oper_prefix "$package")"
    if [[ -z "$value" ]]; then
        _oper_fail "Unable to resolve prefix for ${package}"
        return 1
    fi
    printf -v "$variable" '%s' "$value"
    export "$variable"
}

_oper_clean_path()
{
    local variable="$1" entry result=""
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        case "$entry" in
            /scratch/lus/dev|/scratch/lus/dev/*|\
            /scratch/lus/arw/model/src/jedi|/scratch/lus/arw/model/src/jedi/*|\
            /scratch/lus/arw/model/src/ioda|/scratch/lus/arw/model/src/ioda/*|\
            /scratch/lus/arw/model/src/iodaconv|/scratch/lus/arw/model/src/iodaconv/*|\
            /scratch/lus/arw/spack-stack-1.9.3-gnu|/scratch/lus/arw/spack-stack-1.9.3-gnu/*|\
            /scratch/lus/arw/spack-stack-1.9.3-intel|/scratch/lus/arw/spack-stack-1.9.3-intel/*)
                continue
                ;;
        esac
        case ":$result:" in *":$entry:"*) continue ;; esac
        result="${result:+${result}:}${entry}"
    done < <(tr ':' '\n' <<< "${!variable:-}")
    printf -v "$variable" '%s' "$result"
    export "$variable"
}

_oper_cleanup()
{
    unset -f _oper_log _oper_fail _oper_load _oper_prefix _oper_set_root
    unset -f _oper_clean_path _oper_cleanup
}

_oper_log "Resetting the module environment"
module purge || { _oper_fail "module purge failed"; _oper_cleanup; return 1; }
hash -r

_oper_log "Clearing inherited build and runtime variables"
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Variables that can redirect compilers, Spack, Python, libraries or model tools.
unset LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH
unset CMAKE_PREFIX_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PYTHONPATH PYTHONHOME
unset PYTHONUSERBASE VIRTUAL_ENV CONDA_PREFIX CONDA_DEFAULT_ENV CONDA_EXE
unset SPACK_ENV SPACK_ROOT SPACK_LOADED_HASHES SPACK_ENV_PATH SPACK_USER_CACHE_PATH
unset SPACK_STACK_ROOT SPACK_SYSTEM_CONFIG_PATH SPACK_USER_CONFIG_PATH
unset CC CXX FC F77 F90 MPICC MPICXX MPIFC MPIF77 MPIF90
unset CFLAGS CXXFLAGS CPPFLAGS FCFLAGS FFLAGS LDFLAGS CONFIG_SITE
unset HDF5 HDF5_ROOT HDF5_DIR NETCDF NETCDF_ROOT NETCDF_DIR
unset NETCDF_C_ROOT NETCDF_FORTRAN_ROOT NETCDF_CXX4_ROOT
unset PNETCDF PNETCDF_ROOT PNETCDF_DIR PIO PIO_ROOT PIO_DIR
unset ATLAS_ROOT ECKIT_ROOT FCKIT_ROOT GSIBEC_ROOT ECCODES_ROOT ECBUILD_ROOT
unset JEDI_CMAKE_ROOT GSL_LITE_ROOT BOOST_ROOT EIGEN_ROOT METIS_ROOT FFTW_ROOT
unset NCARG_ROOT NCL_HOME NCL_ROOT GDAL_HOME GDAL_DATA PROJ_LIB PROJ_DATA
unset OMP_NUM_THREADS OMP_STACKSIZE KMP_STACKSIZE KMP_AFFINITY
unset AFAD_OPER_ENV_LOADED CDPATH

export TMPDIR="/scratch/lus/arw/tmp"
export TMP="$TMPDIR" TEMP="$TMPDIR"
mkdir -p "$TMPDIR" || { _oper_fail "Unable to create $TMPDIR"; _oper_cleanup; return 1; }
chmod 700 "$TMPDIR" 2>/dev/null || true

export OPER_STACK_ROOT="/scratch/lus/arw/spack-stack-oper"
export OPER_SPACK_ROOT="$OPER_STACK_ROOT/spack-stack"
export OPER_INSTALL_ROOT="$OPER_STACK_ROOT/installs/oneapi-2024.2.0"
export OPER_MODULE_ROOT="$OPER_INSTALL_ROOT/modulefiles"
export OPER_ENV_ROOT="$OPER_SPACK_ROOT/envs/unified-dev.afad.oneapi-2024.2.0"
export SPACK_STACK_DIR="${OPER_SPACK_ROOT}"
export SPACK_SETUP="$OPER_SPACK_ROOT/spack/share/spack/setup-env.sh"

# Internal runtime cache. It is generated automatically after a successful
# normal environment load and reused by subsequent operational jobs.
OPER_CACHE_DIR="$OPER_STACK_ROOT/cache"
OPER_CACHE_FILE="$OPER_CACHE_DIR/switch_to_oper.runtime.cache.sh"

for directory in "$OPER_SPACK_ROOT" "$OPER_MODULE_ROOT"; do
    [[ -d "$directory" ]] || {
        _oper_fail "Required directory does not exist: $directory"
        unset directory
        _oper_cleanup
        return 1
    }
done
unset directory

# --------------------------------------------------------------------------
# Fast path: load the environment previously generated by this same script.
#
# The cache is accepted only when it is newer than both this script and the
# operational module tree. A failed validation automatically falls back to
# the complete module-loading procedure below.
# --------------------------------------------------------------------------
cache_ok=0

if [[ "${AFAD_ENABLE_SPACK_CLI:-0}" != "1" && \
      "${AFAD_REBUILD_OPER_CACHE:-0}" != "1" && \
      -r "$OPER_CACHE_FILE" && \
      "$OPER_CACHE_FILE" -nt "${BASH_SOURCE[0]}" && \
      "$OPER_CACHE_FILE" -nt "$OPER_MODULE_ROOT" ]]; then

    _oper_log "Loading cached operational environment: $OPER_CACHE_FILE"

    source "$OPER_CACHE_FILE" && cache_ok=1

    if [[ "$cache_ok" -eq 1 ]]; then
        hash -r

        for command_name in cc CC ftn python; do
            if ! command -v "$command_name" >/dev/null 2>&1; then
                _oper_fail "Cached environment is missing command: $command_name"
                cache_ok=0
            fi
        done
        unset command_name
    fi

    if [[ "$cache_ok" -eq 1 ]]; then
        for required_root in \
            "${HDF5_ROOT:-}" \
            "${NETCDF_C_ROOT:-}" \
            "${NETCDF_FORTRAN_ROOT:-}" \
            "${PIO_ROOT:-}" \
            "${ATLAS_ROOT:-}" \
            "${ECKIT_ROOT:-}" \
            "${FCKIT_ROOT:-}" \
            "${GSIBEC_ROOT:-}"
        do
            if [[ -z "$required_root" || ! -d "$required_root" ]]; then
                _oper_fail "Cached environment contains a missing package prefix: ${required_root:-NOT_SET}"
                cache_ok=0
            fi
        done
        unset required_root
    fi

    if [[ "$cache_ok" -eq 1 ]]; then
        case "$(type -P cc):$(type -P CC):$(type -P ftn)" in
            /opt/cray/pe/craype/*/bin/cc:/opt/cray/pe/craype/*/bin/CC:/opt/cray/pe/craype/*/bin/ftn)
                ;;
            *)
                _oper_fail "Cached environment does not select the HPE Cray wrappers"
                cache_ok=0
                ;;
        esac
    fi

    if [[ "$cache_ok" -eq 1 ]]; then

        export AFAD_OPER_ENV_CACHE_LOADED=1

        export AFAD_OPER_ENV_LOADED=1
        export AFAD_OPER_ENV_CACHE_LOADED=1

        _oper_log "Cached operational environment loaded successfully"

        echo
        echo "SUCCESS: Operational Intel MPAS-JEDI environment loaded"
        printf '%-19s = %s\n' \
            "Environment mode" "cached" \
            "Operational root" "$OPER_STACK_ROOT" \
            "Module root" "$OPER_MODULE_ROOT" \
            "cc" "$(type -P cc)" \
            "CC" "$(type -P CC)" \
            "ftn" "$(type -P ftn)" \
            "python" "$(type -P python)" \
            "NetCDF-C" "$NETCDF_C_ROOT" \
            "NetCDF-Fortran" "$NETCDF_FORTRAN_ROOT" \
            "HDF5" "$HDF5_ROOT" \
            "ParallelIO" "$PIO_ROOT" \
            "GSIBEC" "$GSIBEC_ROOT" \
            "TMPDIR" "$TMPDIR"

        unset cache_ok OPER_CACHE_DIR OPER_CACHE_FILE
        _oper_cleanup
        return 0
    fi

    _oper_log "Cached environment failed validation; rebuilding it"
else
    if [[ "${AFAD_REBUILD_OPER_CACHE:-0}" == "1" ]]; then
        _oper_log "Forced runtime-cache rebuild requested"
    else
        _oper_log "No valid runtime cache found; building the full environment"
    fi
fi

unset cache_ok

_oper_load "PrgEnv-intel/8.5.0" || { _oper_cleanup; return 1; }

if [[ ":${LOADEDMODULES:-}:" == *":intel/2024.2:"* ]]; then
    _oper_log "Replacing intel/2024.2 with intel-oneapi/2024.2"
    module swap intel/2024.2 intel-oneapi/2024.2 || {
        module unload intel/2024.2
        module load intel-oneapi/2024.2
    } || { _oper_cleanup; return 1; }
else
    _oper_load "intel-oneapi/2024.2" || { _oper_cleanup; return 1; }
fi

# PrgEnv-intel already supplies craype, network, MPI, libfabric and LibSci.
_oper_load "craype-x86-rome" || { _oper_cleanup; return 1; }
module unload cuda >/dev/null 2>&1 || true

_oper_log "Adding operational Tcl module tree"
module use "$OPER_MODULE_ROOT" || { _oper_cleanup; return 1; }

# Main operational meta-module. Most dependencies come from this module.
_oper_load "jedi-base-env/1.0.0-none-none-hnl24wj" || { _oper_cleanup; return 1; }

# These two are operational additions not currently pulled by jedi-base-env.
_oper_load "jasper/4.2.8-intel-oneapi-compilers-2024.2.0-n7m74hm" || { _oper_cleanup; return 1; }
_oper_load "metis/5.1.0-intel-oneapi-compilers-2024.2.0-q4p5kfj" || { _oper_cleanup; return 1; }
_oper_load "mpifileutils/0.12-intel-oneapi-compilers-2024.2.0-dbxcngw" || { _oper_cleanup; return 1; }
_oper_load "nco/5.3.9-gcc-13.2.1-g4lfkc4" || { _oper_cleanup; return 1; }
_oper_load "gdal/3.10.2-intel-oneapi-compilers-2024.2.0-vhfuiwd" || { _oper_cleanup; return 1; }

_oper_log "Removing obsolete paths"
for variable in PATH LD_LIBRARY_PATH LIBRARY_PATH CPATH CMAKE_PREFIX_PATH PKG_CONFIG_PATH PYTHONPATH; do
    _oper_clean_path "$variable"
done
unset variable
hash -r

# Resolve only roots used by operational build/run scripts.
for definition in \
    'HDF5_ROOT hdf5' \
    'NETCDF_C_ROOT netcdf-c' \
    'NETCDF_FORTRAN_ROOT netcdf-fortran' \
    'NETCDF_CXX4_ROOT netcdf-cxx4' \
    'PNETCDF_ROOT parallel-netcdf' \
    'PIO_ROOT parallelio' \
    'ATLAS_ROOT ecmwf-atlas' \
    'ECKIT_ROOT eckit' \
    'FCKIT_ROOT fckit' \
    'GSIBEC_ROOT gsibec' \
    'ECCODES_ROOT eccodes' \
    'ECBUILD_ROOT ecbuild' \
    'JEDI_CMAKE_ROOT jedi-cmake' \
    'GSL_LITE_ROOT gsl-lite' \
    'BOOST_ROOT boost' \
    'EIGEN_ROOT eigen' \
    'METIS_ROOT metis'
do
    read -r variable package <<< "$definition"
    _oper_set_root "$variable" "$package" || {
        unset definition variable package
        _oper_cleanup
        return 1
    }
done
unset definition variable package

FFTW_ROOT="$(_oper_prefix fftw 2>/dev/null || true)"
export FFTW_ROOT

# Compatibility aliases retained for existing config/build scripts.
export HDF5="$HDF5_ROOT" HDF5_DIR="$HDF5_ROOT" HDF5_PREFIX="$HDF5_ROOT" hdf5_ROOT="$HDF5_ROOT"
export NETCDF="$NETCDF_C_ROOT" NETCDF_ROOT="$NETCDF_C_ROOT" NETCDF_DIR="$NETCDF_C_ROOT" NetCDF_ROOT="$NETCDF_C_ROOT"
export NetCDF_Fortran_ROOT="$NETCDF_FORTRAN_ROOT" netCDF_Fortran_ROOT="$NETCDF_FORTRAN_ROOT"
export PNETCDF="$PNETCDF_ROOT" PNETCDF_DIR="$PNETCDF_ROOT" PNETCDF_PREFIX="$PNETCDF_ROOT" PnetCDF_ROOT="$PNETCDF_ROOT"
export PIO="$PIO_ROOT" PIO_DIR="$PIO_ROOT" PIO_PREFIX="$PIO_ROOT"
export ParallelIO_ROOT="$PIO_ROOT" parallelio_ROOT="$PIO_ROOT" PIO_C_ROOT="$PIO_ROOT" PIO_Fortran_ROOT="$PIO_ROOT"
export atlas_ROOT="$ATLAS_ROOT" ecmwf_atlas_ROOT="$ATLAS_ROOT"
export eckit_ROOT="$ECKIT_ROOT" fckit_ROOT="$FCKIT_ROOT" gsibec_ROOT="$GSIBEC_ROOT"
export eccodes_ROOT="$ECCODES_ROOT" ecbuild_ROOT="$ECBUILD_ROOT"
export jedi_cmake_ROOT="$JEDI_CMAKE_ROOT" jedi_cmake_root="$JEDI_CMAKE_ROOT"
export gsl_lite_ROOT="$GSL_LITE_ROOT"

# Keep Cray wrappers authoritative. Loaded modules already provide dependency paths.
export PATH="/opt/cray/pe/craype/2.7.32/bin:$PATH:/scratch/lus/arw/bin"
export CC=cc CXX=CC FC=ftn F77=ftn F90=ftn
export MPICC=cc MPICXX=CC MPIFC=ftn MPIF77=ftn MPIF90=ftn
export CRAYPE_LINK_TYPE=dynamic CRAY_CPU_TARGET=x86-rome CONFIG_SITE=
export CFLAGS="-pthread" CXXFLAGS="-pthread" LDFLAGS="-pthread"
export F_UFMTENDIAN='big:101-200'
export HDF5_USE_FILE_LOCKING=FALSE FI_CXI_RX_MATCH_MODE=hybrid I_MPI_EXTRA_FILESYSTEM=ON
export OMP_NUM_THREADS=1 OMP_STACKSIZE=512M KMP_STACKSIZE=512M KMP_AFFINITY=disabled
hash -r

for command_name in cc CC ftn python; do
    command -v "$command_name" >/dev/null 2>&1 || {
        _oper_fail "Required command not found: $command_name"
        unset command_name
        _oper_cleanup
        return 1
    }
done
unset command_name

case "$(type -P cc):$(type -P CC):$(type -P ftn)" in
    /opt/cray/pe/craype/*/bin/cc:/opt/cray/pe/craype/*/bin/CC:/opt/cray/pe/craype/*/bin/ftn) ;;
    *) _oper_fail "HPE Cray compiler wrappers are not first in PATH"; _oper_cleanup; return 1 ;;
esac

# Spack command-line initialization is unnecessary for normal operational jobs.
# Loaded Tcl modules already provide the required runtime paths and libraries.
#
# Enable only for interactive Spack administration:
#     export AFAD_ENABLE_SPACK_CLI=1
#     source "$HOME/spack-stack-oper/switch_to_oper.sh"

if [[ "${AFAD_ENABLE_SPACK_CLI:-0}" == "1" ]]; then
    _oper_log "Initializing optional Spack command-line environment"

    if [[ -r "$SPACK_SETUP" ]]; then
        source "$SPACK_SETUP"
    else
        _oper_fail "Spack initialization file not found: $SPACK_SETUP"
        _oper_cleanup
        return 1
    fi

    command -v spack >/dev/null 2>&1 || {
        _oper_fail "Spack command is unavailable after initialization"
        _oper_cleanup
        return 1
    }

    if [[ -d "$OPER_ENV_ROOT" && -r "$OPER_ENV_ROOT/spack.yaml" ]]; then
        spack env activate "$OPER_ENV_ROOT" || {
            _oper_fail "Unable to activate Spack environment: $OPER_ENV_ROOT"
            _oper_cleanup
            return 1
        }
    else
        _oper_fail "Spack environment is missing or invalid: $OPER_ENV_ROOT"
        _oper_cleanup
        return 1
    fi

    _oper_log "Activated optional Spack environment: ${SPACK_ENV:-UNKNOWN}"
else
    unset SPACK_ENV
    _oper_log "Skipping Spack command-line initialization for operational runtime"
fi

# --------------------------------------------------------------------------
# Generate the internal runtime cache after a successful complete load.
# Do not overwrite the runtime cache when the optional Spack CLI environment
# has been activated.
# --------------------------------------------------------------------------
if [[ "${AFAD_ENABLE_SPACK_CLI:-0}" != "1" ]]; then
    _oper_log "Writing operational runtime cache"

    mkdir -p "$OPER_CACHE_DIR" || {
        _oper_fail "Unable to create cache directory: $OPER_CACHE_DIR"
    }

    if [[ -d "$OPER_CACHE_DIR" ]]; then
        CACHE_TMP="${OPER_CACHE_FILE}.tmp.$$"

        python - "$CACHE_TMP" <<'PY_CACHE'
import os
import pathlib
import shlex
import sys

output = pathlib.Path(sys.argv[1])

excluded_names = {
    "_",
    "PWD",
    "OLDPWD",
    "SHLVL",
    "RANDOM",
    "SECONDS",
    "LINENO",
    "PIPESTATUS",
    "BASHPID",
    "PPID",
    "HISTFILE",
    "HISTCMD",
    "DISPLAY",
    "TERM",
    "SSH_CLIENT",
    "SSH_CONNECTION",
    "SSH_TTY",
    "AFAD_ENABLE_SPACK_CLI",
    "AFAD_REBUILD_OPER_CACHE",
    "AFAD_OPER_ENV_LOADED",
    "AFAD_OPER_ENV_CACHE_LOADED",
    "SPACK_ENV",
    "SPACK_ENV_PATH",
    "PELOCAL_PRGENV",
    "PROFILEREAD",
}

excluded_prefixes = (
    "SLURM_",
    "PBS_",
    "LSB_",
    "PMI_",
    "PMIX_",
    "SSH_",
    "XDG_",
    "SYSTEMD_",
    "BASH_FUNC_",
)

lines = [
    "#!/bin/bash",
    "# Automatically generated by switch_to_oper.sh.",
    "# Do not edit this file manually.",
    "",
]

for name in sorted(os.environ):
    if name in excluded_names:
        continue

    if name.startswith(excluded_prefixes):
        continue

    value = os.environ[name]
    lines.append(f"export {name}={shlex.quote(value)}")

lines.extend([
    "",
    "export AFAD_OPER_ENV_CACHE_LOADED=1",
    "",
])

try:
    output.write_text("\n".join(lines))
    output.chmod(0o600)
    print(f"SUCCESS: prepared runtime cache {output}")
except Exception as exc:
    print(f"FAILED: could not prepare runtime cache {output}: {exc}")
PY_CACHE

        if [[ -s "$CACHE_TMP" ]]; then
            mv -f "$CACHE_TMP" "$OPER_CACHE_FILE" &&
                _oper_log "Runtime cache created: $OPER_CACHE_FILE"
        else
            _oper_fail "Runtime cache generation produced no usable file"
            rm -f "$CACHE_TMP"
        fi

        unset CACHE_TMP
    fi
fi

export AFAD_OPER_ENV_LOADED=1
export AFAD_OPER_ENV_CACHE_LOADED=0

echo
echo "SUCCESS: Operational Intel MPAS-JEDI environment loaded"
printf '%-19s = %s\n' \
    "Operational root" "$OPER_STACK_ROOT" \
    "Module root" "$OPER_MODULE_ROOT" \
    "Spack CLI" "${AFAD_ENABLE_SPACK_CLI:-0}" \
    "Spack environment" "${SPACK_ENV:-NOT_ACTIVATED}" \
    "cc" "$(type -P cc)" \
    "CC" "$(type -P CC)" \
    "ftn" "$(type -P ftn)" \
    "python" "$(type -P python)" \
    "NetCDF-C" "$NETCDF_C_ROOT" \
    "NetCDF-Fortran" "$NETCDF_FORTRAN_ROOT" \
    "HDF5" "$HDF5_ROOT" \
    "ParallelIO" "$PIO_ROOT" \
    "TMPDIR" "$TMPDIR"

_oper_cleanup
return 0
