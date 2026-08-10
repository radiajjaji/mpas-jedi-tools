#!/bin/bash

nicasDir=/scratch/lus/arw/jedi/mpas_only/4.0.0/NICAS
nicasMergeDir=${nicasDir}/merge

nlocal=768           #User's configuration
cores_per_node=128  #Derecho

list_vars="stream_function velocity_potential temperature spechum surface_pressure qc qi qr qs qg"
#list_vars="stream_function velocity_potential temperature spechum surface_pressure"


workdir=${nicasMergeDir}

mkdir -p ${workdir}
cd ${workdir}


# First merging the "local" NICAS files.
# Number of local files
ntotpad=$(printf "%.6d" "${nlocal}")

for itot in $(seq 1 ${nlocal}); do
   itotpad=$(printf "%.6d" "${itot}")

   # Local full files names
   filename_full=mpas_nicas_local_${ntotpad}-${itotpad}.nc
   filename_grids_full=mpas_nicas_grids_local_${ntotpad}-${itotpad}.nc

   # Remove existing local full files
   rm -f ${filename_full}
   rm -f ${filename_grids_full}

   # Create scripts to merge local files
   echo "#!/bin/bash" > merge_nicas_${itotpad}.bash
   for variable in ${list_vars}; do
      filename="../${variable}/${filename_full}"
      echo -e "ncks -A ${filename} ${filename_full}" >> merge_nicas_${itotpad}.bash
      echo -e "ncatted -O -a eulaVlliF_,global,d,, ${filename_full}" >> merge_nicas_${itotpad}.bash
      filename_grids="../${variable}/${filename_grids_full}"
      echo -e "ncks -A ${filename_grids} ${filename_grids_full}" >> merge_nicas_${itotpad}.bash
      echo -e "ncatted -O -a eulaVlliF_,global,d,, ${filename_grids_full}" >> merge_nicas_${itotpad}.bash
   done
done


# Second: merging the "global" NICAS files.
# Global full files names
filename_full=mpas_nicas.nc

# Remove existing global full files.
rm -f ${filename_full}

# Create script to merge global files
nlocalp1=$((nlocal+1))
itotpad=$(printf "%.6d" "${nlocalp1}")
echo "#!/bin/bash" > merge_nicas_${itotpad}.bash
for variable in ${list_vars}; do
   filename="../${variable}/${filename_full}"
   echo -e "ncks -A ${filename} ${filename_full}" >> merge_nicas_${itotpad}.bash
   echo -e "ncatted -O -a eulaVlliF_,global,d,, ${filename_full}" >> merge_nicas_${itotpad}.bash
done


# Run scripts in parallel
cat > qsub.bash << EOF
#!/bin/bash
#SBATCH --job-name=NICASmerge
#SBATCH --partition=opr
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128
#SBATCH --time=00:10:00
#SBATCH --output=/scratch/lus/arw/jedi/mpas_only/4.0.0/logs/NICASmerge.%j.out
#SBATCH --error=/scratch/lus/arw/jedi/mpas_only/4.0.0/logs/NICASmerge.%j.err


# Timer
SECONDS=0
nbatch=\$((${nlocalp1}/${cores_per_node}+1))
itot=0
for ibatch in \$(seq 1 \${nbatch}); do
   for i in \$(seq 1 ${cores_per_node}); do
      itot=\$((itot+1))
      if test "\${itot}" -le "${nlocalp1}"; then
         itotpad=\$(printf "%.6d" "\${itot}")
         echo "Batch \${ibatch} - job \${i}: ./merge_nicas_\${itotpad}.bash"
         chmod 755 merge_nicas_\${itotpad}.bash
         ./merge_nicas_\${itotpad}.bash &
      fi
   done
   wait
done

# Timer
wait
echo "ELAPSED TIME = \${SECONDS} s"

# Clean up all scripts
rm ./merge_nicas_??????.bash
EOF


#https://docs.pace.gatech.edu/software/jobDepend/
Job_ID=`sbatch qsub.bash`
echo ${Job_ID} > job_id.txt


#Other diagnostics:  nicas_norm, dirac_nicas
for variable in ${list_vars}; do
  ncks -A -v ${variable} ../${variable}/mpas.nicas_norm.nc   mpas.nicas_norm.nc
  ncks -A -v ${variable} ../${variable}/mpas.dirac_nicas.nc  mpas.dirac_nicas.nc
done


cd ../..
