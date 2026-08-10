#!/bin/bash

nicasDir=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/NICAS
nicasMergeDir=${nicasDir}/merge

nlocal=768
cores_per_node=128

list_vars="stream_function velocity_potential temperature spechum surface_pressure qc qi qr qs qg"

workdir=${nicasMergeDir}

mkdir -p ${workdir}
mkdir -p /scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs

cd ${workdir} || {
    echo "FAILED: cannot enter ${workdir}"
    return 1 2>/dev/null || false
}

echo "============================================================"
echo "NICAS MERGE - 24 km"
echo "NICAS directory : ${nicasDir}"
echo "Merge directory : ${nicasMergeDir}"
echo "Variables       : ${list_vars}"
echo "Local files     : ${nlocal}"
echo "============================================================"

# ----------------------------------------------------------------------
# Validate all input products first
# ----------------------------------------------------------------------

ntotpad=$(printf "%.6d" "${nlocal}")

for variable in ${list_vars}; do

    echo "Checking ${variable} ..."

    test -s "../${variable}/mpas_nicas.nc" || {
        echo "FAILED: ../${variable}/mpas_nicas.nc missing"
        return 1 2>/dev/null || false
    }

    test -s "../${variable}/mpas.nicas_norm.nc" || {
        echo "FAILED: ../${variable}/mpas.nicas_norm.nc missing"
        return 1 2>/dev/null || false
    }

    test -s "../${variable}/mpas.dirac_nicas.nc" || {
        echo "FAILED: ../${variable}/mpas.dirac_nicas.nc missing"
        return 1 2>/dev/null || false
    }

    test -s "../${variable}/mpas_nicas_local_${ntotpad}-000001.nc" || {
        echo "FAILED: first local NICAS file missing for ${variable}"
        return 1 2>/dev/null || false
    }

    test -s "../${variable}/mpas_nicas_grids_local_${ntotpad}-000001.nc" || {
        echo "FAILED: first local NICAS grid file missing for ${variable}"
        return 1 2>/dev/null || false
    }
done

echo "SUCCESS: all NICAS input groups are present"

# ----------------------------------------------------------------------
# Remove only previous MERGED products/scripts
# ----------------------------------------------------------------------

rm -f mpas_nicas.nc
rm -f mpas.nicas_norm.nc
rm -f mpas.dirac_nicas.nc
rm -f mpas_nicas_local_${ntotpad}-??????.nc
rm -f mpas_nicas_grids_local_${ntotpad}-??????.nc
rm -f merge_nicas_??????.bash
rm -f qsub.bash
rm -f job_id.txt

# ----------------------------------------------------------------------
# First: merge the local NICAS files
# ----------------------------------------------------------------------

echo "Creating ${nlocal} local merge scripts ..."

for itot in $(seq 1 ${nlocal}); do

    itotpad=$(printf "%.6d" "${itot}")

    filename_full=mpas_nicas_local_${ntotpad}-${itotpad}.nc
    filename_grids_full=mpas_nicas_grids_local_${ntotpad}-${itotpad}.nc

    cat > merge_nicas_${itotpad}.bash << EOF_LOCAL
#!/bin/bash

rm -f ${filename_full}
rm -f ${filename_grids_full}

for variable in ${list_vars}; do

    filename="../\${variable}/${filename_full}"
    filename_grids="../\${variable}/${filename_grids_full}"

    if [ ! -s "\${filename}" ]; then
        echo "FAILED: missing \${filename}"
        return 1 2>/dev/null || false
    fi

    if [ ! -s "\${filename_grids}" ]; then
        echo "FAILED: missing \${filename_grids}"
        return 1 2>/dev/null || false
    fi

    ncks -A "\${filename}" ${filename_full} || {
        echo "FAILED: ncks \${filename}"
        return 1 2>/dev/null || false
    }

    ncatted -O -a eulaVlliF_,global,d,, ${filename_full}

    ncks -A "\${filename_grids}" ${filename_grids_full} || {
        echo "FAILED: ncks \${filename_grids}"
        return 1 2>/dev/null || false
    }

    ncatted -O -a eulaVlliF_,global,d,, ${filename_grids_full}

done
EOF_LOCAL

    chmod 755 merge_nicas_${itotpad}.bash
done

# ----------------------------------------------------------------------
# Second: merge global NICAS files
# ----------------------------------------------------------------------

filename_full=mpas_nicas.nc

nlocalp1=$((nlocal + 1))
itotpad=$(printf "%.6d" "${nlocalp1}")

cat > merge_nicas_${itotpad}.bash << EOF_GLOBAL
#!/bin/bash

rm -f ${filename_full}

for variable in ${list_vars}; do

    filename="../\${variable}/${filename_full}"

    if [ ! -s "\${filename}" ]; then
        echo "FAILED: missing \${filename}"
        return 1 2>/dev/null || false
    fi

    ncks -A "\${filename}" ${filename_full} || {
        echo "FAILED: ncks \${filename}"
        return 1 2>/dev/null || false
    }

    ncatted -O -a eulaVlliF_,global,d,, ${filename_full}

done
EOF_GLOBAL

chmod 755 merge_nicas_${itotpad}.bash

# ----------------------------------------------------------------------
# Merge norm and Dirac diagnostics now.
# These do not depend on the local/global merge batch job.
# ----------------------------------------------------------------------

echo "Merging normalization and Dirac diagnostics ..."

rm -f mpas.nicas_norm.nc
rm -f mpas.dirac_nicas.nc

for variable in ${list_vars}; do

    echo "  diagnostics: ${variable}"

    ncks -A -v ${variable} \
        ../${variable}/mpas.nicas_norm.nc \
        mpas.nicas_norm.nc || {
        echo "FAILED: normalization merge for ${variable}"
        return 1 2>/dev/null || false
    }

    ncks -A -v ${variable} \
        ../${variable}/mpas.dirac_nicas.nc \
        mpas.dirac_nicas.nc || {
        echo "FAILED: Dirac merge for ${variable}"
        return 1 2>/dev/null || false
    }

done

echo "SUCCESS: diagnostic files merged"

# ----------------------------------------------------------------------
# Run 768 local merges + one global merge in parallel
# ----------------------------------------------------------------------

cat > qsub.bash << 'EOF_BATCH'
#!/bin/bash
#SBATCH --job-name=NICASmerge24
#SBATCH --partition=opr
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --time=00:15:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs/NICASmerge.%j.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/3.0.3/24km/logs/NICASmerge.%j.err

SECONDS=0

cd /scratch/lus/arw/jedi/mpas_only/3.0.3/24km/NICAS/merge || {
    echo "FAILED: cannot enter NICAS merge directory"
    return 1 2>/dev/null || false
}

module load nco >/dev/null 2>&1 || true

command -v ncks || {
    echo "FAILED: ncks not found"
    return 1 2>/dev/null || false
}

command -v ncatted || {
    echo "FAILED: ncatted not found"
    return 1 2>/dev/null || false
}

nlocal=768
nlocalp1=$((nlocal + 1))
cores_per_node=128

nbatch=$(( (nlocalp1 + cores_per_node - 1) / cores_per_node ))

itot=0

echo "============================================================"
echo "Starting 24-km NICAS merge"
echo "Total merge scripts : ${nlocalp1}"
echo "Parallel workers    : ${cores_per_node}"
echo "Batches             : ${nbatch}"
echo "============================================================"

for ibatch in $(seq 1 ${nbatch}); do

    echo "Starting batch ${ibatch}/${nbatch}"

    for i in $(seq 1 ${cores_per_node}); do

        itot=$((itot + 1))

        if test "${itot}" -le "${nlocalp1}"; then

            itotpad=$(printf "%.6d" "${itot}")

            echo "Batch ${ibatch} worker ${i}: merge_nicas_${itotpad}.bash"

            ./merge_nicas_${itotpad}.bash &
        fi

    done

    wait

done

echo
echo "Validating merged products ..."

ntotpad=$(printf "%.6d" "${nlocal}")

nlocal_out=$(find . -maxdepth 1 \
    -type f \
    -name "mpas_nicas_local_${ntotpad}-??????.nc" |
    wc -l)

ngrids_out=$(find . -maxdepth 1 \
    -type f \
    -name "mpas_nicas_grids_local_${ntotpad}-??????.nc" |
    wc -l)

nlocal_out=${nlocal_out//[[:space:]]/}
ngrids_out=${ngrids_out//[[:space:]]/}

echo "Merged local files : ${nlocal_out}"
echo "Merged grid files  : ${ngrids_out}"

if [ "${nlocal_out}" -ne 768 ]; then
    echo "FAILED: expected 768 merged local files"
    return 1 2>/dev/null || false
fi

if [ "${ngrids_out}" -ne 768 ]; then
    echo "FAILED: expected 768 merged grid files"
    return 1 2>/dev/null || false
fi

test -s mpas_nicas.nc || {
    echo "FAILED: merged mpas_nicas.nc missing"
    return 1 2>/dev/null || false
}

echo
echo "============================================================"
echo "SUCCESS: 24-km NICAS merge completed"
echo "ELAPSED TIME = ${SECONDS} s"
echo "============================================================"

rm -f ./merge_nicas_??????.bash
EOF_BATCH

echo
echo "Submitting NICAS merge batch job ..."

Job_ID=$(sbatch qsub.bash)

echo "${Job_ID}" > job_id.txt
echo "${Job_ID}"

cd ../..
