#!/bin/bash
# Shared runtime helpers for MPAS-JEDI/SABER-BUMP NMC preprocessing.



# These paths are site/build dependent and may be overridden by the user.
#
# Example:
#   export MPAS_JEDI_INSTALL=$HOME/gnu302/mpas-install
#   export MPAS_JEDI_CODE=$HOME/gnu302/code
#   export MPAS_BUILD=$HOME/gnu302/build/MPAS
#
INSTALL="${MPAS_JEDI_INSTALL:-${HOME}/gnu302/mpas-install}"
CODE="${MPAS_JEDI_CODE:-${HOME}/gnu302/code}"
MPAS_BUILD="${MPAS_BUILD:-${HOME}/gnu302/build/MPAS}"

NAMELISTS="${MPAS_JEDI_NAMELISTS:-${CODE}/mpas-jedi/test/testinput/namelists}"
PHYSICS="${MPAS_PHYSICS_DIR:-${MPAS_BUILD}/core_atmosphere}"

export PATH="$INSTALL/bin:$PATH"
export LD_LIBRARY_PATH="$INSTALL/lib64:$INSTALL/lib:${LD_LIBRARY_PATH:-}"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"
export OMP_STACKSIZE=1G
export OMP_PLACES=cores
export OMP_PROC_BIND=close
export HDF5_USE_FILE_LOCKING=FALSE
export GFORTRAN_CONVERT_UNIT='big_endian:101-200'

ulimit -s unlimited
ulimit -c 0

need_file() {
    [ -s "$1" ] || {
        echo "FATAL: missing file: $1" >&2
        return 1
    }
}

stage_resources() {
    local d="$1"
    local f

    mkdir -p "$d"

    ln -sfn "$NAMELISTS/geovars.yaml" "$d/geovars.yaml"
    ln -sfn "$NAMELISTS/keptvars.yaml" "$d/keptvars.yaml"
    ln -sfn "$CODE/mpas-jedi/test/testinput/obsop_name_map.yaml" "$d/obsop_name_map.yaml"

    for f in analysis background control ensemble; do
        ln -sfn "$NAMELISTS/stream_list.atmosphere.$f" "$d/stream_list.atmosphere.$f"
    done

    for f in "$PHYSICS"/*; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in
            *.TBL|*.DBL|RRTMG_*|RRTM_*|CAM_*|VERSION|COMPATIBILITY)
                ln -sfn "$f" "$d/$(basename "$f")"
                ;;
        esac
    done

    need_file "$d/geovars.yaml"
    need_file "$d/keptvars.yaml"
    need_file "$d/obsop_name_map.yaml"
    need_file "$d/GENPARM.TBL"
    need_file "$d/LANDUSE.TBL"
    need_file "$d/SOILPARM.TBL"
    need_file "$d/VEGPARM.TBL"
    need_file "$d/RRTMG_LW_DATA"
    need_file "$d/RRTMG_SW_DATA"
}

write_streams() {
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
