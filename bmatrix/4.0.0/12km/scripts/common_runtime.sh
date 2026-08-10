#!/bin/bash
# Shared runtime helpers for the MPAS-JEDI 4.0.0 Intel B-matrix workflow.

set -o pipefail

ROOT="${ROOT:-$HOME/jedi/mpas_only/4.0.0}"

GNU400_ROOT="$HOME/gnu400"
INSTALL="${GNU400_ROOT}/mpas-install"
CODE="${GNU400_ROOT}/code"
NAMELISTS="${CODE}/mpas-jedi/test/testinput/namelists"
PHYSICS="${INSTALL}/share/MPAS/core_atmosphere"

export PATH="${INSTALL}/bin:${PATH}"
export LD_LIBRARY_PATH="${INSTALL}/lib64:${INSTALL}/lib:${LD_LIBRARY_PATH:-}"

export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
export OMP_STACKSIZE="${OMP_STACKSIZE:-1G}"
export OMP_PLACES="${OMP_PLACES:-cores}"
export OMP_PROC_BIND="${OMP_PROC_BIND:-close}"

export HDF5_USE_FILE_LOCKING=FALSE

export GFORTRAN_CONVERT_UNIT='big_endian:101-200'
unset F_UFMTENDIAN

# Intel Fortran equivalent of:
#   GFORTRAN_CONVERT_UNIT='big_endian:101-200'
#
# Apply big-endian conversion only to Fortran units 101 through 200.

# Avoid accidentally carrying GNU-specific runtime behavior into Intel jobs.

ulimit -s unlimited
ulimit -c 0

need_file()
{
    [ -s "$1" ] || {
        echo "FATAL: missing file: $1" >&2
        return 1
    }
}

need_dir()
{
    [ -d "$1" ] || {
        echo "FATAL: missing directory: $1" >&2
        return 1
    }
}

stage_resources()
{
    local d="$1"
    local f

    need_dir "$NAMELISTS" || return 1
    need_dir "$PHYSICS" || return 1

    mkdir -p "$d"

    ln -sfn "$NAMELISTS/geovars.yaml" "$d/geovars.yaml"
    ln -sfn "$NAMELISTS/keptvars.yaml" "$d/keptvars.yaml"
    ln -sfn "$CODE/mpas-jedi/test/testinput/obsop_name_map.yaml" \
        "$d/obsop_name_map.yaml"

    for f in analysis background control ensemble; do
        ln -sfn "$NAMELISTS/stream_list.atmosphere.$f" \
            "$d/stream_list.atmosphere.$f"
    done

    for f in "$PHYSICS"/*; do
        [ -e "$f" ] || continue

        case "$(basename "$f")" in
            *.TBL|*.DBL|RRTMG_*|RRTM_*|CAM_*|VERSION|COMPATIBILITY)
                ln -sfn "$f" "$d/$(basename "$f")"
                ;;
        esac
    done

    need_file "$d/geovars.yaml" || return 1
    need_file "$d/keptvars.yaml" || return 1
    need_file "$d/obsop_name_map.yaml" || return 1

    need_file "$d/stream_list.atmosphere.analysis" || return 1
    need_file "$d/stream_list.atmosphere.background" || return 1
    need_file "$d/stream_list.atmosphere.control" || return 1
    need_file "$d/stream_list.atmosphere.ensemble" || return 1

    need_file "$d/GENPARM.TBL" || return 1
    need_file "$d/LANDUSE.TBL" || return 1
    need_file "$d/SOILPARM.TBL" || return 1
    need_file "$d/VEGPARM.TBL" || return 1
    need_file "$d/RRTMG_LW_DATA" || return 1
    need_file "$d/RRTMG_SW_DATA" || return 1
}

write_streams()
{
    local d="$1"
    local grid="$2"

    cat > "$d/streams.atmosphere" <<EOF_STREAMS
<streams>

<immutable_stream name="invariant"
                  type="input"
                  precision="single"
                  filename_template="x1.${grid}.invariant.nc"
                  io_type="pnetcdf,cdf5"
                  input_interval="initial_only" />

<immutable_stream name="input"
                  type="input"
                  precision="single"
                  filename_template="templateFields.${grid}.nc"
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
        type="input;output"
        precision="single"
        io_type="pnetcdf,cdf5"
        filename_template="control.nc"
        input_interval="initial_only"
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
}
