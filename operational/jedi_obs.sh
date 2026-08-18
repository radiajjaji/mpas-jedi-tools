#!/bin/bash
#SBATCH --job-name=JEDI.OBS
#SBATCH --partition=hpclm,uan,slm
#SBATCH --export=ALL
#SBATCH --time=1:15:00
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --no-requeue
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null

###############################################################################
# Clean JEDI observation download + obs2ioda conversion script
#
# Important design:
#   - NO set -u
#   - NO set -e
#   - NO set -o pipefail
#   - source modelenv.sh FIRST, because START_DATE/D/NCEP variables may be there
#   - one clean log file only
#   - one global lock to avoid overlapping executions
#   - unique download directory per RUN_DATE and slot
#   - no pget -c, to avoid silently reusing old BUFR files
#   - process slots serially: gdas1, gdas2, gdas3
#   - reject obs2ioda output if printed BUFR date is not the expected slot date
###############################################################################

###############################################################################
# Start safe shell behavior
###############################################################################
set +e
set +u
set +x

ulimit -s unlimited
ulimit -c 0
umask 022

###############################################################################
# Source operational environment FIRST
###############################################################################
MODELENV="/scratch/lus/arw/model/slurm/modelenv.sh"

if [ -f "$MODELENV" ]; then
    . "$MODELENV" >/dev/null 2>&1
else
    echo "ERROR: missing $MODELENV"
    exit 1
fi

# modelenv.sh may enable xtrace; disable it again.
set +x
set +u
set +e

###############################################################################
# Check required variables after modelenv.sh
###############################################################################
if [ -z "${START_DATE:-}" ]; then
    echo "ERROR: START_DATE is not set after sourcing $MODELENV"
    exit 1
fi

if [ -z "${D:-}" ]; then
    echo "ERROR: D is not set after sourcing $MODELENV"
    exit 1
fi

if [ -z "${NCEP_SITE2:-}" ]; then
    echo "ERROR: NCEP_SITE2 is not set after sourcing $MODELENV"
    exit 1
fi

if [ -z "${NCEP_DIR:-}" ]; then
    echo "ERROR: NCEP_DIR is not set after sourcing $MODELENV"
    exit 1
fi

RUN_DATE="$START_DATE"

case "$RUN_DATE" in
    ??????????) ;;
    *)
        echo "ERROR: START_DATE must be YYYYMMDDHH, got: $RUN_DATE"
        exit 1
        ;;
esac

RUN_YEAR=${RUN_DATE:0:4}
RUN_MONTH=${RUN_DATE:4:2}
RUN_DAY=${RUN_DATE:6:2}
RUN_CYCLE=${RUN_DATE:8:2}

R="${R:-/scratch/lus/arw/model/log}"
mkdir -p "$R"

JEDI_ROOT="$D/jedi/r${RUN_CYCLE}"
mkdir -p "$JEDI_ROOT"

LOG="$R/jedi.obs.${RUN_DATE}.log"
: > "$LOG"

# Send all stdout/stderr to the single clean log.
exec >> "$LOG" 2>&1

###############################################################################
# Logging helpers
###############################################################################
ts() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

log() {
    echo "[$(ts)] $*"
}

section() {
    echo
    echo "==============================================================================="
    echo "[$(ts)] $*"
    echo "==============================================================================="
}

###############################################################################
# Global lock: avoid overlapping executions
###############################################################################
LOCKFILE="${JEDI_OBS_GLOBAL_LOCK:-$R/jedi.obs.GLOBAL.lock}"

exec 9>"$LOCKFILE"
flock -n 9
LOCK_RC=$?

if [ "$LOCK_RC" -ne 0 ]; then
    log "Another jedi_obs job is already running."
    log "Lock file: $LOCKFILE"
    log "Exiting to avoid overlapping download/conversion."
    exit 9
fi

section "JEDI OBS JOB STARTED"
log "RUN_DATE=$RUN_DATE"
log "RUN_CYCLE=$RUN_CYCLE"
log "JEDI_ROOT=$JEDI_ROOT"
log "LOG=$LOG"
log "HOST=$(hostname)"
log "SLURM_JOB_ID=${SLURM_JOB_ID:-none}"
log "LOCKFILE=$LOCKFILE"

###############################################################################
# Load modules
###############################################################################
section "LOADING MODULES"

module load PrgEnv-intel
module switch intel intel-oneapi
module load cray-netcdf-hdf5parallel
module load cray-hdf5-parallel
module load cray-parallel-netcdf
module load craype-hugepages8M
module load cray-mpich
module load craype-x86-rome
module load libfabric
module load cray-libsci
module load craype-network-ofi
module load craype
module load perftools-base
module load cray-dsmml
module load cray-python
module load xpmem/2.9.6-1.1_20240510205610__g087dc11fc19d
module unload cuda >/dev/null 2>&1

# make sure xtrace remains off after modules
set +x
set +u
set +e

log "Modules loaded."

###############################################################################
# Executables
###############################################################################
OBS2IODA_ROOT="${OBS2IODA_ROOT:-/scratch/lus/arw/model/src/obs2ioda_v3_src/build}"
OBS2IODA_EXE="${OBS2IODA_EXE:-$OBS2IODA_ROOT/bin/obs2ioda_v3}"

MPASJEDI_INSTALL="${MPASJEDI_INSTALL:-/scratch/lus/arw/jedi/mpas-install}"
IODA_VALIDATE_EXE="${IODA_VALIDATE_EXE:-$MPASJEDI_INSTALL/bin/ioda-validate.x}"
IODA_VALIDATE_YAML="${IODA_VALIDATE_YAML:-}"

LFTP_CMD="${LFTP:-/scratch/lus/dev/bin/lftp}"

if [ ! -x "$OBS2IODA_EXE" ]; then
    log "ERROR: obs2ioda executable not found or not executable: $OBS2IODA_EXE"
    exit 2
fi

if [ ! -x "$LFTP_CMD" ]; then
    log "ERROR: lftp executable not found or not executable: $LFTP_CMD"
    exit 2
fi

DO_VALIDATE=0
if [ -n "$IODA_VALIDATE_YAML" ]; then
    if [ ! -x "$IODA_VALIDATE_EXE" ]; then
        log "ERROR: IODA_VALIDATE_YAML is set but validator is not executable: $IODA_VALIDATE_EXE"
        exit 2
    fi
    if [ ! -s "$IODA_VALIDATE_YAML" ]; then
        log "ERROR: IODA_VALIDATE_YAML is set but file is missing/empty: $IODA_VALIDATE_YAML"
        exit 2
    fi
    DO_VALIDATE=1
fi

log "OBS2IODA_EXE=$OBS2IODA_EXE"
log "LFTP_CMD=$LFTP_CMD"
log "DO_VALIDATE=$DO_VALIDATE"
if [ "$DO_VALIDATE" -eq 1 ]; then
    log "IODA_VALIDATE_EXE=$IODA_VALIDATE_EXE"
    log "IODA_VALIDATE_YAML=$IODA_VALIDATE_YAML"
fi

###############################################################################
# Date utility
###############################################################################
date_shift_from_base() {
    base="$1"
    dh="$2"

    if [ -n "${SMSDATE:-}" ] && command -v "$SMSDATE" >/dev/null 2>&1; then
        "$SMSDATE" "$dh" "$base"
    else
        y=${base:0:4}
        m=${base:4:2}
        d=${base:6:2}
        h=${base:8:2}
        date -u -d "${y}-${m}-${d} ${h}:00:00 ${dh} hours" +%Y%m%d%H
    fi
}

ANALYSIS_DATE=$(date_shift_from_base "$RUN_DATE" -12)
SLOT1=$(date_shift_from_base "$ANALYSIS_DATE" -6)
SLOT2="$ANALYSIS_DATE"
SLOT3=$(date_shift_from_base "$ANALYSIS_DATE" +6)

log "ANALYSIS_DATE=$ANALYSIS_DATE"
log "SLOT1=$SLOT1"
log "SLOT2=$SLOT2"
log "SLOT3=$SLOT3"

###############################################################################
# Prepare directories
###############################################################################
section "PREPARING DIRECTORIES"

DOWNLOAD_ROOT="$JEDI_ROOT/download_${RUN_DATE}"
WORK_ROOT="$JEDI_ROOT/work_obs_${RUN_DATE}"

log "Removing old HDF5 outputs for this cycle directory."
rm -f "$JEDI_ROOT"/*_obs_*.h5 2>/dev/null

log "Removing old OK markers for this RUN_DATE."
rm -f "$JEDI_ROOT"/OK.GETOBS."$RUN_DATE" 2>/dev/null
rm -f "$JEDI_ROOT"/OK.PROCOBS."$RUN_DATE" 2>/dev/null
rm -f "$JEDI_ROOT"/OK.OBS."$RUN_DATE" 2>/dev/null

log "Removing old isolated directories for RUN_DATE=$RUN_DATE only."
rm -rf "$DOWNLOAD_ROOT" "$WORK_ROOT"
mkdir -p "$DOWNLOAD_ROOT" "$WORK_ROOT"

###############################################################################
# Observation list
###############################################################################
OBS_ITEMS="
prepbufr prepbufr.nr required
adpsfc adpsfc.tm00.bufr_d.nr optional
adpupa adpupa.tm00.bufr_d optional
satwnd satwnd.tm00.bufr_d optional
1bamua 1bamua.tm00.bufr_d optional
1bhrs4 1bhrs4.tm00.bufr_d optional
1bmhs 1bmhs.tm00.bufr_d optional
ssmisu ssmisu.tm00.bufr_d optional
gpsro gpsro.tm00.bufr_d.nr optional
gpsipw gpsipw.tm00.bufr_d.nr optional
atms atms.tm00.bufr_d optional
geoimr geoimr.tm00.bufr_d optional
gome gome.tm00.bufr_d optional
omi omi.tm00.bufr_d optional
osbuv8 osbuv8.tm00.bufr_d optional
eshrs3 eshrs3.tm00.bufr_d optional
esmhs esmhs.tm00.bufr_d optional
sevasr sevasr.tm00.bufr_d optional
mtiasi mtiasi.tm00.bufr_d optional
"

###############################################################################
# Download one slot
###############################################################################
download_slot() {
    tag="$1"
    stream="$2"
    slotdate="$3"

    y=${slotdate:0:4}
    m=${slotdate:4:2}
    d=${slotdate:6:2}
    h=${slotdate:8:2}

    slotdir="$DOWNLOAD_ROOT/${tag}_${slotdate}"
    scr="$slotdir/lftp.scr"
    out="$slotdir/lftp.out"
    remote_dir="$NCEP_DIR/${stream}.${y}${m}${d}/."

    mkdir -p "$slotdir"

    section "DOWNLOADING $tag slotdate=$slotdate stream=$stream"
    log "Remote directory: $remote_dir"
    log "Local directory : $slotdir"

    cat > "$scr" << EOF
open $NCEP_SITE2
set cmd:fail-exit no
set net:max-retries 2
set net:timeout 300
cd $remote_dir
EOF

    echo "$OBS_ITEMS" | while read key suffix required; do
        [ -z "$key" ] && continue

        remote="${stream}.t${h}z.${suffix}"
        localfile="$slotdir/${tag}.${slotdate}.${remote}"

        rm -f "$localfile"

        # No pget -c here. Fresh exact-slot download only.
        echo "pget -n8 $remote -o $localfile" >> "$scr"
    done

    echo "quit" >> "$scr"

    log "Starting lftp for $tag $slotdate"
    log "Download progress/output follows:"

    "$LFTP_CMD" -f "$scr" 2>&1 | tee "$out"
    lftp_rc=${PIPESTATUS[0]}

    log "lftp finished for $tag $slotdate with rc=$lftp_rc"

    if grep -E "Access failed|No such file|Login failed|Fatal|ERROR|Timeout|Not Found" "$out" >/dev/null 2>&1; then
        log "Download warnings/errors seen for $tag $slotdate:"
        grep -E "Access failed|No such file|Login failed|Fatal|ERROR|Timeout|Not Found" "$out" | sed 's/^/  /'
    fi

    rm -f "$scr"

    required_file="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.prepbufr.nr"

    if [ -s "$required_file" ]; then
        log "Required prepbufr OK: $(basename "$required_file")"
        return 0
    fi

    log "Required prepbufr MISSING: $required_file"
    return 10
}

###############################################################################
# Find downloaded file
###############################################################################
find_downloaded() {
    tag="$1"
    stream="$2"
    slotdate="$3"
    key="$4"

    h=${slotdate:8:2}
    slotdir="$DOWNLOAD_ROOT/${tag}_${slotdate}"

    case "$key" in
        prepbufr)
            f="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.prepbufr.nr"
            ;;
        satwnd)
            f="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.satwnd.tm00.bufr_d"
            ;;
        gpsro)
            f="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.gpsro.tm00.bufr_d.nr"
            ;;
        amsua)
            f="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.1bamua.tm00.bufr_d"
            ;;
        mhs)
            f="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.1bmhs.tm00.bufr_d"
            ;;
        iasi)
            f="$slotdir/${tag}.${slotdate}.${stream}.t${h}z.mtiasi.tm00.bufr_d"
            ;;
        *)
            return 1
            ;;
    esac

    if [ -s "$f" ]; then
        echo "$f"
        return 0
    fi

    return 1
}

link_if_present() {
    src="$1"
    dst="$2"

    if [ -n "$src" ] && [ -s "$src" ]; then
        ln -sfn "$src" "$dst"
        return 0
    fi

    return 1
}

###############################################################################
# obs2ioda date check
###############################################################################
check_obs2ioda_dates() {
    tmpout="$1"
    expected="$2"
    bad=0

    found_dates=$(grep -E "file date is:" "$tmpout" | awk '{print $NF}' | sort -u)

    if [ -z "$found_dates" ]; then
        log "WARNING: obs2ioda did not print any file-date lines."
        return 0
    fi

    echo "$found_dates" | while read d; do
        [ -z "$d" ] && continue
        if [ "$d" != "$expected" ]; then
            echo "BAD_DATE_FOUND $d"
        fi
    done > "$tmpout.datecheck"

    if grep -q "BAD_DATE_FOUND" "$tmpout.datecheck"; then
        while read label d; do
            log "DATE MISMATCH: obs2ioda read $d but expected $expected"
        done < "$tmpout.datecheck"
        rm -f "$tmpout.datecheck"
        return 1
    fi

    rm -f "$tmpout.datecheck"
    log "Date coherence OK: obs2ioda input date matches $expected"
    return 0
}

###############################################################################
# Process one slot
###############################################################################
process_slot() {
    tag="$1"
    stream="$2"
    slotdate="$3"

    work="$WORK_ROOT/${tag}_${slotdate}"
    tmpout="$work/obs2ioda.out"

    section "PROCESSING $tag slotdate=$slotdate stream=$stream"

    rm -rf "$work"
    mkdir -p "$work"

    cd "$work" || return 20

    prep_src=$(find_downloaded "$tag" "$stream" "$slotdate" prepbufr)
    satwnd_src=$(find_downloaded "$tag" "$stream" "$slotdate" satwnd)
    gnssro_src=$(find_downloaded "$tag" "$stream" "$slotdate" gpsro)
    amsua_src=$(find_downloaded "$tag" "$stream" "$slotdate" amsua)
    mhs_src=$(find_downloaded "$tag" "$stream" "$slotdate" mhs)
    iasi_src=$(find_downloaded "$tag" "$stream" "$slotdate" iasi)

    if [ -z "$prep_src" ]; then
        log "SKIP $tag $slotdate: required prepbufr missing."
        return 2
    fi

    log "Supported obs2ioda inputs:"
    [ -n "$prep_src" ] && log "  prepbufr : $(basename "$prep_src")"
    [ -n "$satwnd_src" ] && log "  satwnd   : $(basename "$satwnd_src")"
    [ -n "$gnssro_src" ] && log "  gpsro    : $(basename "$gnssro_src")"
    [ -n "$amsua_src" ] && log "  amsua    : $(basename "$amsua_src")"
    [ -n "$mhs_src" ] && log "  mhs      : $(basename "$mhs_src")"
    [ -n "$iasi_src" ] && log "  iasi     : $(basename "$iasi_src")"

    link_if_present "$prep_src" prepbufr.bufr
    if [ $? -ne 0 ]; then
        log "ERROR: failed to link prepbufr.bufr"
        return 3
    fi

    link_if_present "$satwnd_src" satwnd.bufr
    link_if_present "$gnssro_src" gnssro.bufr
    link_if_present "$amsua_src" amsua.bufr
    link_if_present "$mhs_src" mhs.bufr
    link_if_present "$iasi_src" iasi.bufr

    # obs2ioda_v3 support files
    ln -sfn /scratch/lus/arw/model/src/obs2ioda/obs_errtable.satwnd obs_errtable
    if [ -f /scratch/lus/arw/model/src/obs2ioda/obs_errtable ]; then
        ln -sfn /scratch/lus/arw/model/src/obs2ioda/obs_errtable obs_errtable.default
    fi

    ln -sfn /scratch/lus/arw/model/src/obs2ioda/iasi_metop-a.SpcCoeff.bin .
    ln -sfn /scratch/lus/arw/model/src/obs2ioda/iasi_metop-b.SpcCoeff.bin .
    ln -sfn /scratch/lus/arw/model/src/obs2ioda/iasi_metop-c.SpcCoeff.bin .

    log "Executing obs2ioda_v3..."
    "$OBS2IODA_EXE" > "$tmpout" 2>&1
    obs_rc=$?

    sed 's/^/  obs2ioda | /' "$tmpout"

    check_obs2ioda_dates "$tmpout" "$slotdate"
    date_rc=$?

    if [ "$date_rc" -ne 0 ]; then
        log "Rejecting $tag $slotdate because obs2ioda read wrong-date BUFR."
        rm -f *_obs_*.h5
        return 30
    fi

    if [ "$obs_rc" -ne 0 ]; then
        log "obs2ioda_v3 FAILED for $tag $slotdate with rc=$obs_rc"
        return "$obs_rc"
    fi

    nout=0
    for f in *_obs_*.h5; do
        [ -e "$f" ] || continue
        [ -s "$f" ] || continue

        if [ "$DO_VALIDATE" -eq 1 ]; then
            log "Validating $(basename "$f")"
            "$IODA_VALIDATE_EXE" "$IODA_VALIDATE_YAML" "$f"
            val_rc=$?
            if [ "$val_rc" -ne 0 ]; then
                log "Validation FAILED for $(basename "$f") rc=$val_rc"
                return 40
            fi
        fi

        cp -f "$f" "$JEDI_ROOT/"
        nout=$((nout + 1))
    done

    if [ "$nout" -gt 0 ]; then
        log "SUCCESS $tag $slotdate: copied $nout HDF5 files to $JEDI_ROOT"
        return 0
    fi

    log "NO HDF5 outputs produced for $tag $slotdate"
    return 5
}

###############################################################################
# Main workflow
###############################################################################
section "DOWNLOAD STAGE"

download_rc=0

download_slot gdas1 gdas "$SLOT1"
rc=$?
[ "$rc" -ne 0 ] && download_rc=1
log "Download gdas1 rc=$rc"

download_slot gdas2 gdas "$SLOT2"
rc=$?
[ "$rc" -ne 0 ] && download_rc=1
log "Download gdas2 rc=$rc"

download_slot gdas3 gfs "$SLOT3"
rc=$?
[ "$rc" -ne 0 ] && download_rc=1
log "Download gdas3 rc=$rc"

if [ "$download_rc" -eq 0 ]; then
    touch "$JEDI_ROOT/OK.GETOBS.${RUN_DATE}"
    log "Download stage SUCCESS for all required prepbufr files."
else
    log "Download stage PARTIAL/FAILED for at least one slot."
    log "Continuing to process slots that have required prepbufr."
fi

section "OBS2IODA CONVERSION STAGE"

ok_any=0
fail_any=0
skip_any=0

process_slot gdas1 gdas "$SLOT1"
rc=$?
case "$rc" in
    0) ok_any=1 ;;
    2) skip_any=1 ;;
    *) fail_any=1 ;;
esac
log "Process gdas1 rc=$rc"

process_slot gdas2 gdas "$SLOT2"
rc=$?
case "$rc" in
    0) ok_any=1 ;;
    2) skip_any=1 ;;
    *) fail_any=1 ;;
esac
log "Process gdas2 rc=$rc"

process_slot gdas3 gfs "$SLOT3"
rc=$?
case "$rc" in
    0) ok_any=1 ;;
    2) skip_any=1 ;;
    *) fail_any=1 ;;
esac
log "Process gdas3 rc=$rc"

###############################################################################
# Final summary
###############################################################################
section "FINAL SUMMARY"

log "HDF5 outputs in $JEDI_ROOT:"
find "$JEDI_ROOT" -maxdepth 1 -type f -name '*_obs_*.h5' -printf '  %f %s bytes\n' | sort

nh5=$(find "$JEDI_ROOT" -maxdepth 1 -type f -name '*_obs_*.h5' | wc -l | awk '{print $1}')
log "Total HDF5 output files: $nh5"

if [ "${JEDI_OBS_KEEP_WORK:-0}" = "1" ]; then
    log "Keeping work directory: $WORK_ROOT"
else
    log "Cleaning work directory: $WORK_ROOT"
    rm -rf "$WORK_ROOT"
fi

if [ "$ok_any" -eq 1 ] && [ "$fail_any" -eq 0 ]; then
    touch "$JEDI_ROOT/OK.PROCOBS.${RUN_DATE}"
    touch "$JEDI_ROOT/OK.OBS.${RUN_DATE}"
    log "SUCCESS: all processable slots completed cleanly."
    exit 0
fi

if [ "$ok_any" -eq 1 ] && [ "$fail_any" -eq 1 ]; then
    log "PARTIAL SUCCESS: at least one slot produced HDF5, but at least one slot failed."
    exit 1
fi

if [ "$ok_any" -eq 0 ] && [ "$skip_any" -eq 1 ] && [ "$fail_any" -eq 0 ]; then
    log "NO DATA: no slots had required supported input."
    exit 1
fi

log "FAILURE: no usable HDF5 output produced."
exit 1
