# JEDI Observation Preparation Example — 2026081812

This directory contains a real operational execution log from
`operational/jedi_obs.sh`.

## Run

Operational run date:

    2026081812

The script derives the JEDI analysis time as:

    RUN_DATE - 12 hours

and prepares three observation slots:

    analysis - 6 h
    analysis time
    analysis + 6 h

For this operational cycle the workflow downloads NCEP GDAS/GFS BUFR data,
checks the validity time of each slot, converts supported observations with
`obs2ioda_v3`, and places the resulting IODA HDF5 files under the operational
JEDI observation directory.

## Principal observation inputs

The download stage includes:

    prepbufr
    adpsfc
    adpupa
    satwnd
    AMSU-A
    HIRS
    MHS
    SSMIS
    GNSSRO
    GPS-IPW
    ATMS
    GEO imager
    GOME
    OMI
    SBUV
    IASI

Only observation types supported by the operational `obs2ioda_v3` conversion
are linked into each conversion work directory.

## Data-integrity protection

The script contains several protections against stale or inconsistent
observations:

- one global execution lock;
- a unique download directory for each run and slot;
- no resumed `pget -c` downloads;
- required `prepbufr` validation;
- explicit comparison between the BUFR date reported by `obs2ioda_v3`
  and the expected slot date;
- rejection of converted output when the dates disagree.

## Products

IODA HDF5 products are written under:

    $D/jedi/r${RUN_CYCLE}

Successful processing creates operational marker files including:

    OK.GETOBS.${RUN_DATE}
    OK.PROCOBS.${RUN_DATE}
    OK.OBS.${RUN_DATE}

The complete original execution log is:

    jedi.obs.2026081812.log

Related script:

    ../../operational/jedi_obs.sh
