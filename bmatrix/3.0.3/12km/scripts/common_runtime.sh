#!/bin/bash
#===============================================================================
# Shared runtime helpers for the operational Intel MPAS-JEDI 3.0.3 workflows.
#
# This file does not load modules. The calling job must source:
#   /scratch/lus/arw/model/slurm/modelenv.sh
#   $HOME/spack-stack-oper/switch_to_oper.sh
# before sourcing this file.
#===============================================================================

set -o pipefail

ROOT="${ROOT:-$HOME/jedi/mpas_only/3.0.3}"

MPASJEDI_BUNDLE_ROOT="${MPASJEDI_BUNDLE_ROOT:-$HOME/intel303}"
MPASJEDI_INSTALL="${MPASJEDI_INSTALL:-$MPASJEDI_BUNDLE_ROOT/mpas-install}"
MPASJEDI_CODE="${MPASJEDI_CODE:-$MPASJEDI_BUNDLE_ROOT/code}"
MPASJEDI_BUILD="${MPASJEDI_BUILD:-$MPASJEDI_BUNDLE_ROOT/build}"

JEDI_NAMELISTS="${JEDI_NAMELISTS:-$MPASJEDI_CODE/mpas-jedi/test/testinput/namelists}"
JEDI_OBSOP_NAME_MAP="${JEDI_OBSOP_NAME_MAP:-$MPASJEDI_CODE/mpas-jedi/test/testinput/obsop_name_map.yaml}"
JEDI_PHYSICS_DIR="${JEDI_PHYSICS_DIR:-$MPASJEDI_BUILD/mpas-jedi/test}"

export PATH="$MPASJEDI_INSTALL/bin:$PATH"
export LD_LIBRARY_PATH="$MPASJEDI_INSTALL/lib64:$MPASJEDI_INSTALL/lib:${LD_LIBRARY_PATH:-}"

export OMP_NUM_THREADS=1
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

need_file() {
    [ -s "$1" ] || {
        echo "FATAL: missing or empty file: $1" >&2
        return 1
    }
}

need_dir() {
    [ -d "$1" ] || {
        echo "FATAL: missing directory: $1" >&2
        return 1
    }
}

stage_resources() {
    local dest="$1"
    local f base

    mkdir -p "$dest"

    need_dir "$JEDI_NAMELISTS" || return 1
    need_file "$JEDI_OBSOP_NAME_MAP" || return 1

    ln -sfn "$JEDI_NAMELISTS/geovars.yaml" "$dest/geovars.yaml"
    ln -sfn "$JEDI_NAMELISTS/keptvars.yaml" "$dest/keptvars.yaml"
    ln -sfn "$JEDI_OBSOP_NAME_MAP" "$dest/obsop_name_map.yaml"

    for f in analysis background control ensemble; do
        need_file "$JEDI_NAMELISTS/stream_list.atmosphere.$f" || return 1
        ln -sfn "$JEDI_NAMELISTS/stream_list.atmosphere.$f" \
            "$dest/stream_list.atmosphere.$f"
    done

    if [ -d "$JEDI_PHYSICS_DIR" ]; then
        for f in "$JEDI_PHYSICS_DIR"/*; do
            [ -e "$f" ] || continue
            base="$(basename "$f")"
            case "$base" in
                *.TBL|*.DBL|RRTMG_*|RRTM_*|CAM_*|VERSION|COMPATIBILITY)
                    ln -sfn "$f" "$dest/$base"
                    ;;
            esac
        done
    fi

    need_file "$dest/geovars.yaml" || return 1
    need_file "$dest/keptvars.yaml" || return 1
    need_file "$dest/obsop_name_map.yaml" || return 1
    need_file "$dest/stream_list.atmosphere.background" || return 1
    need_file "$dest/stream_list.atmosphere.control" || return 1
    need_file "$dest/stream_list.atmosphere.ensemble" || return 1
    need_file "$dest/stream_list.atmosphere.analysis" || return 1

    for f in GENPARM.TBL LANDUSE.TBL SOILPARM.TBL VEGPARM.TBL \
             RRTMG_LW_DATA RRTMG_SW_DATA; do
        need_file "$dest/$f" || return 1
    done
}

write_streams() {
    local dest="$1"
    local xnn="$2"
    local grid="$3"

    cat > "$dest/streams.atmosphere" <<EOF_STREAMS
<streams>

<immutable_stream name="invariant"
                  type="input"
                  precision="single"
                  filename_template="${xnn}.${grid}.invariant.nc"
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
        type="output"
        precision="single"
        io_type="pnetcdf,cdf5"
        filename_template="control.nc"
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

    need_file "$dest/streams.atmosphere"
}
