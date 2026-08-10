#!/bin/bash
set -euo pipefail

# ==============================================================================
# MPAS-Bundle 3.0.3 configuration using the operational Intel Spack stack
#
# Toolchain:
#   HPE Cray PrgEnv-intel/8.5.0
#   Intel oneAPI 2024.2 through cc/CC/ftn
#   Cray MPICH 8.1.30
#
# Dependencies:
#   All external dependencies are supplied by:
#     /scratch/lus/arw/spack-stack-oper
#
# Environment loader:
#   ${HOME}/intel303/switch_to_oper.sh
# ==============================================================================

readonly MPS_ROOT="${MPS_ROOT:-${HOME}/intel303}"
readonly MPS_CODE="${MPS_CODE:-${MPS_ROOT}/code}"
readonly MPS_BUILD="${MPS_BUILD:-${MPS_ROOT}/build}"
readonly MPS_INSTALL="${MPS_INSTALL:-${MPS_ROOT}/mpas-install}"
readonly LOGDIR="${LOGDIR:-${MPS_ROOT}/logs}"
readonly SWITCH_ENV="${SWITCH_ENV:-${HOME}/spack-stack-oper/switch_to_oper.sh}"

mkdir -p "$LOGDIR"
readonly LOGFILE="${LOGDIR}/config.ecbuild.$(date -u +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log()       { printf '[%s] %s\n' "$(timestamp)" "$*"; }
fatal()     { printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        fatal "Required command not found: $1"
}

require_dir() {
    [[ -d "$1" ]] || fatal "Required directory not found: $1"
}

require_file() {
    [[ -f "$1" ]] || fatal "Required file not found: $1"
}

require_root() {
    local name="$1"
    local value="${!name:-}"
    [[ -n "$value" ]] || fatal "$name is not defined after sourcing $SWITCH_ENV"
    [[ -d "$value" ]] || fatal "$name does not exist: $value"
    log "$name=$value"
}

# ==============================================================================
# 1. Reuse or load the operational Intel Spack-stack environment
# ==============================================================================

# Check whether a module is loaded. The argument may be either:
#   - a complete module name, such as PrgEnv-intel/8.5.0
#   - a module family, such as jedi-base-env
module_loaded() {
    local wanted="$1"
    local loaded

    IFS=':' read -r -a loaded <<< "${LOADEDMODULES:-}"

    for loaded_module in "${loaded[@]}"; do
        [[ -n "$loaded_module" ]] || continue

        if [[ "$loaded_module" == "$wanted" ||
              "$loaded_module" == "$wanted/"* ]]; then
            return 0
        fi
    done

    return 1
}

oper_environment_loaded() {
    module_loaded "PrgEnv-intel"  || return 1
    module_loaded "intel-oneapi"  || return 1
    module_loaded "cray-mpich"    || return 1
    module_loaded "jedi-base-env" || return 1
    module_loaded "parallel-netcdf" || return 1
    module_loaded "parallelio"    || return 1

    return 0
}

if oper_environment_loaded; then
    log "Operational Intel MPAS-JEDI environment is already loaded; reusing it."
    export AFAD_OPER_ENV_LOADED=1
else
    require_file "$SWITCH_ENV"

    log "Operational Intel MPAS-JEDI environment is not fully loaded."
    log "Sourcing $SWITCH_ENV"

    # shellcheck disable=SC1090
    source "$SWITCH_ENV" ||
        fatal "Failed to source $SWITCH_ENV"

    oper_environment_loaded ||
        fatal "Required operational modules remain incomplete after sourcing $SWITCH_ENV"

    export AFAD_OPER_ENV_LOADED=1
fi

for cmd in cc CC ftn icx icpx ifx cmake ecbuild git make python \
           nc-config nf-config pnetcdf-config; do
    require_command "$cmd"
done

case "$(command -v cc)" in
    /opt/cray/pe/craype/*/bin/cc) ;;
    *) fatal "cc is not the HPE Cray wrapper: $(command -v cc)" ;;
esac

case "$(command -v CC)" in
    /opt/cray/pe/craype/*/bin/CC) ;;
    *) fatal "CC is not the HPE Cray wrapper: $(command -v CC)" ;;
esac

case "$(command -v ftn)" in
    /opt/cray/pe/craype/*/bin/ftn) ;;
    *) fatal "ftn is not the HPE Cray wrapper: $(command -v ftn)" ;;
esac

require_dir "$MPS_CODE"
require_file "$MPS_CODE/CMakeLists.txt"

# ==============================================================================
# 2. Validate the stack dependency roots
# ==============================================================================

for root_name in \
    HDF5_ROOT \
    NETCDF_C_ROOT \
    NETCDF_FORTRAN_ROOT \
    PNETCDF_ROOT \
    PIO_ROOT \
    ATLAS_ROOT \
    ECKIT_ROOT \
    FCKIT_ROOT \
    GSIBEC_ROOT \
    ECCODES_ROOT
do
    require_root "$root_name"
done

# CMAKE_PREFIX_PATH is constructed by the loaded Spack modulefiles and augmented
# by switch_to_oper.sh. Reject known foreign development trees.
for var_name in PATH LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH \
                CPLUS_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH PYTHONPATH
do
    var_value="${!var_name:-}"
    if printf '%s\n' "$var_value" | tr ':' '\n' |
       grep -Eq '^/scratch/lus/dev(/|$)|/scratch/lus/arw/model/src/(jedi|ioda|iodaconv)(/|$)|spack-stack-1\.9\.3-(gnu|intel)(/|$)'
    then
        fatal "$var_name contains a foreign or obsolete dependency path"
    fi
done

# ==============================================================================
# 3. Compiler and runtime settings
# ==============================================================================

export CC=cc
export CXX=CC
export FC=ftn
export F77=ftn
export F90=ftn

export MPICC=cc
export MPICXX=CC
export MPIFC=ftn
export MPIF77=ftn
export MPIF90=ftn

export CRAYPE_LINK_TYPE=dynamic
export CRAY_CPU_TARGET=x86-rome
export HDF5_USE_FILE_LOCKING=FALSE
export F_UFMTENDIAN='big:101-200'
unset CONFIG_SITE

export TMPDIR="${TMPDIR:-/scratch/lus/arw/tmp}"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
mkdir -p "$TMPDIR"
chmod 700 "$TMPDIR" 2>/dev/null || true

unset GFORTRAN_CONVERT_UNIT GFORTRAN_UNBUFFERED_ALL GFORTRAN_ERROR_BACKTRACE
unset CPPFLAGS CFLAGS CXXFLAGS FCFLAGS FFLAGS LDFLAGS

# IntelLLVM flags passed through the Cray compiler wrappers.
readonly C_FLAGS="-O3 -g -pthread -fp-model=precise"
readonly CXX_FLAGS="-O3 -g -pthread -fp-model=precise"
readonly FORTRAN_FLAGS="-O3 -g -traceback -fp-model=precise"

# ==============================================================================
# 4. Toolchain and ABI sanity tests
# ==============================================================================

log "Loaded modules:"
module list

log "Compiler identities:"
cc --version 2>&1 | head -n 2
CC --version 2>&1 | head -n 2
ftn --version 2>&1 | head -n 2

log "Stack NetCDF/PnetCDF versions:"
nc-config --version
nf-config --version
pnetcdf-config --version

TESTDIR="${TMPDIR}/intel303_config_test.$$"
trap 'rm -rf "$TESTDIR"' EXIT
mkdir -p "$TESTDIR"

cat > "$TESTDIR/test_netcdf.f90" <<'EOF'
program test_netcdf
  use netcdf
  implicit none
  integer :: ncid, ierr

  ierr = nf90_create('test.nc', NF90_CLOBBER, ncid)
  if (ierr /= nf90_noerr) stop 1

  ierr = nf90_close(ncid)
  if (ierr /= nf90_noerr) stop 2
end program test_netcdf
EOF

(
    cd "$TESTDIR"

    # Use the exact flags and libraries exported by the Spack-stack nf-config.
    # shellcheck disable=SC2046
    ftn $FORTRAN_FLAGS \
        $(nf-config --fflags) \
        test_netcdf.f90 \
        $(nf-config --flibs) \
        -o test_netcdf.x

    ./test_netcdf.x
)
log "Spack-stack NetCDF-Fortran compile/link/runtime test passed."

# ==============================================================================
# 5. Prepare clean build and install trees
# ==============================================================================

log "Removing $MPS_BUILD"
rm -rf "$MPS_BUILD"

log "Removing $MPS_INSTALL"
rm -rf "$MPS_INSTALL"

mkdir -p "$MPS_BUILD" "$MPS_INSTALL"
cd "$MPS_BUILD"

# ==============================================================================
# 6. Configure MPAS-Bundle 3.0.3
# ==============================================================================

cmake_args=(
    --build=Release
    "$MPS_CODE"

    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_INSTALL_PREFIX=$MPS_INSTALL"

    "-DCMAKE_C_COMPILER=cc"
    "-DCMAKE_CXX_COMPILER=CC"
    "-DCMAKE_Fortran_COMPILER=ftn"

    "-DCMAKE_C_FLAGS=$C_FLAGS"
    "-DCMAKE_CXX_FLAGS=$CXX_FLAGS"
    "-DCMAKE_Fortran_FLAGS=$FORTRAN_FLAGS"

    "-DBUILD_SHARED_LIBS=ON"
    "-DBUILD_TESTING=ON"
    "-DENABLE_TESTS=ON"

    "-DENABLE_BUMP=ON"
    "-DENABLE_QUENCH=ON"
    "-DENABLE_UFO_DATA=ON"
    "-DENABLE_IODA_DATA=ON"
    "-DENABLE_MPAS_JEDI_DATA=ON"
    "-DENABLE_MKL=OFF"

    # Use the operational Spack-stack installations of these dependencies.
    "-DBUNDLE_SKIP_ECKIT=OFF"
    "-DBUNDLE_SKIP_FCKIT=OFF"
    "-DBUNDLE_SKIP_ATLAS=OFF"
    "-DBUNDLE_SKIP_ODC=OFF"
    "-DBUNDLE_SKIP_ROPP-UFO=ON"
    "-DBUNDLE_SKIP_RTTOV=ON"

    "-DMPAS_DOUBLE_PRECISION=ON"
    "-DMPAS_CORES=init_atmosphere;atmosphere"
    "-DMPAS_USE_PIO=ON"
    "-DDO_PHYSICS=ON"
    "-DMPAS_OPENMP=OFF"
    "-DMPAS_PROFILE=OFF"

    "-DHDF5_ROOT=$HDF5_ROOT"
    "-DHDF5_PREFER_PARALLEL=ON"

    "-DNetCDF_ROOT=$NETCDF_C_ROOT"
    "-DNETCDF_ROOT=$NETCDF_C_ROOT"
    "-DNetCDF_Fortran_ROOT=$NETCDF_FORTRAN_ROOT"
    "-DnetCDF_Fortran_ROOT=$NETCDF_FORTRAN_ROOT"

    "-DPNETCDF_ROOT=$PNETCDF_ROOT"
    "-DPnetCDF_ROOT=$PNETCDF_ROOT"

    "-DPIO_ROOT=$PIO_ROOT"
    "-DParallelIO_ROOT=$PIO_ROOT"
    "-Dparallelio_ROOT=$PIO_ROOT"

    "-Datlas_ROOT=$ATLAS_ROOT"
    "-Deckit_ROOT=$ECKIT_ROOT"
    "-Dfckit_ROOT=$FCKIT_ROOT"
    "-Dgsibec_ROOT=$GSIBEC_ROOT"
    "-Deccodes_ROOT=$ECCODES_ROOT"

    "-DMPIEXEC_EXECUTABLE=/usr/bin/srun"
    "-DMPIEXEC_NUMPROC_FLAG=-n"

    "-Wno-dev"
)

log "Configuring MPAS-Bundle 3.0.3"
printf '  %q' ecbuild "${cmake_args[@]}"
printf '\n'

ecbuild "${cmake_args[@]}"

log "Configuration completed successfully."

# ==============================================================================
# 7. Build and install
# ==============================================================================

JOBS="${JOBS:-16}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] ||
    fatal "JOBS must be a positive integer, received: $JOBS"

if [[ "${BUILD_AFTER_CONFIGURE:-yes}" == "yes" ]]; then
    log "Building with $JOBS parallel jobs"
    cmake --build "$MPS_BUILD" --parallel "$JOBS"

    log "Installing into $MPS_INSTALL"
    cmake --install "$MPS_BUILD"

    log "Build and installation completed successfully."
else
    log "Configuration-only mode selected."
    printf 'cmake --build %q --parallel %q\n' "$MPS_BUILD" "$JOBS"
    printf 'cmake --install %q\n' "$MPS_BUILD"
fi

log "Log file: $LOGFILE"
