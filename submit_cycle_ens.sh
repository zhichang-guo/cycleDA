#!/bin/bash -l
#SBATCH --job-name=offline_noahmp
#SBATCH --account=gsienkf
#SBATCH --qos=debug
#SBATCH --nodes=1
#SBATCH --tasks-per-node=6
#SBATCH --cpus-per-task=1
#SBATCH -t 00:10:00
#SBATCH -o log_noahmp.%j.log
#SBATCH -e err_noahmp.%j.err

##########
# to do: 
# -specify resolution in this script (currently fixed at 96) 
# -decide how to manage soil moisture DA. Separate DA script to snow? 
# -add ensemble options

# experiment name 

exp_name=open_testing
#exp_name=DA_testing

################################################################
# specify DA and Ensemble options (all should be "YES" or "NO") 
################################################################

export do_DA=NO   # do full DA update
do_hofx=NO  # use JEDI to calculate hofx, but do not do update 
            # only used if do_DA=NO  
do_ens=YES # If "YES"  do ensemble run

# DA options (select "YES" to assimilate or calcualte hofx) 
DAtype="letkfoi_snow" # for snow, use "letkfoi_snow" 
export ASSIM_IMS=YES
export ASSIM_GHCN=YES
export ASSIM_SYNTH=NO
if [[ $do_DA == "YES" || $do_hofx == "YES" ]]; then  # do DA
   do_jedi=YES
   # construct yaml name
   if [ $do_DA == "YES" ]; then
        JEDI_YAML=${DAtype}"_offline_DA"
   elif [ $do_hofx == "YES" ]; then
        JEDI_YAML=${DAtype}"_offline_hofx"
   fi

   if  [ ASSIM_IMS=="YES" ]; then JEDI_YAML=${JEDI_YAML}"_IMS" ; fi
   if  [ ASSIM_GHCN=="YES" ]; then JEDI_YAML=${JEDI_YAML}"_GHCN" ; fi

   JEDI_YAML=${JEDI_YAML}"_C96.yaml" # IMS and GHCN

   echo "JEDI YAML is: "$JEDI_YAML

   if [[ ! -e ./landDA_workflow/jedi/fv3-jedi/yaml_files/$JEDI_YAML ]]; then
        echo "YAML does not exist, exiting" 
        exit
   fi
   export JEDI_YAML
else
   do_jedi=NO
fi

# set your directories
export WORKDIR=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/TestcycleDA/experiment1/workdir/ # temporary work dir
export OUTDIR=/scratch1/NCEPDEV/stmp4/Zhichang.Guo/Work/TestcycleDA/experiment1/${exp_name}/output/

dates_per_job=2

# Match the variable names in forcing files to those in land drivers
# for examples: precipitation_conserve in the forcing files will be used for precipitaton
#            or precipitation01 in the forcing files will be used for precipitation for the first ensemble member
frc_in_list=(precipitation temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)
frc_in_file=(precipitation temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)
#frc_in_file=(precipitation_conserve temperature specific_humidity wind_speed surface_pressure solar_radiation longwave_radiation)
variable_size=${#frc_in_list[@]}

# Specify ensemble list for do_ens
if [ $do_ens == "YES" ]; then
  ens_list=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30)
  ensemble_size=${#ens_list[@]}
else
  ensemble_size=1
fi

######################################################
# shouldn't need to change anything below here

SAVEDIR=${OUTDIR}/restarts # dir to save restarts
MODLDIR=${OUTDIR}/noahmp # dir to save noah-mp output

# create output dircetories if they do not already exist.
if [[ ! -e ${OUTDIR} ]]; then
    mkdir -p ${OUTDIR}/DA
    mkdir ${OUTDIR}/DA/IMSproc 
    mkdir ${OUTDIR}/DA/jedi_incr
    mkdir ${OUTDIR}/DA/logs
    mkdir ${OUTDIR}/DA/hofx
    mkdir ${OUTDIR}/restarts
    mkdir ${OUTDIR}/restarts/vector
    mkdir ${OUTDIR}/restarts/tile
    mkdir ${OUTDIR}/noahmp
fi

source cycle_mods_bash

# executables

CYCLEDIR=$(pwd)  # this directory
#vec2tileexec=${CYCLEDIR}/vector2tile/vector2tile_converter.exe
vec2tileexec=/scratch2/BMC/gsienkf/Clara.Draper/gerrit-hera/AZworkflow/vector2tile/vector2tile_converter.exe
#LSMexec=${CYCLEDIR}/ufs_land_driver/ufsLand.exe 
LSMexec=/scratch2/NCEPDEV/stmp3/Zhichang.Guo/EMCLandPreP7/ufs-land-driver/run/ufsLand.exe
DAscript=${CYCLEDIR}/landDA_workflow/do_snowDA.sh 
export DADIR=${CYCLEDIR}/landDA_workflow/

analdate=${CYCLEDIR}/analdates.sh
incdate=${CYCLEDIR}/incdate.sh

logfile=${CYCLEDIR}/cycle.log
touch $logfile

# read in dates 
source ${analdate}

echo "***************************************" >> $logfile
echo "cycling from $STARTDATE to $ENDDATE" >> $logfile

# If there is no restart in experiment directory, copy from current directory

sYYYY=`echo $STARTDATE | cut -c1-4`
sMM=`echo $STARTDATE | cut -c5-6`
sDD=`echo $STARTDATE | cut -c7-8`
sHH=`echo $STARTDATE | cut -c9-10`

if [ $do_ens == "YES" ]; then
    for ens_member in "${ens_list[@]}"
    do
        source_restart=/scratch2/NCEPDEV/stmp3/Zhichang.Guo/GEFS/exps/ufs_land_restart.ens${ens_member}.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
        target_restart=${SAVEDIR}/vector/ufs_land_restart.ens${ens_member}_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc
        if [[ ! -e ${target_restart} ]]; then
            cp ${source_restart} ${target_restart}
        fi
    done
else
    if [[ ! -e ${OUTDIR}/restarts/vector/ufs_land_restart_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc ]]; then

    cp ./ufs_land_restart.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc ${OUTDIR}/restarts/vector/ufs_land_restart_back.${sYYYY}-${sMM}-${sDD}_${sHH}-00-00.nc

    fi
fi

THISDATE=$STARTDATE

date_count=0

while [ $date_count -lt $dates_per_job ]; do

    if [ $THISDATE -ge $ENDDATE ]; then 
        echo "All done, at date ${THISDATE}"  >> $logfile
        cd $CYCLEDIR 
        rm -rf $WORKDIR
        exit  
    fi

    echo "starting $THISDATE"  

    # Create output directory and temporary workdir for ecah ensemble member
    if [[ -d $WORKDIR ]]; then
      rm -rf $WORKDIR
    fi

    mkdir $WORKDIR
    cd $WORKDIR

    if [ $do_ens == "YES" ]; then
        for ens_member in "${ens_list[@]}"
        do
            ENSEMBLE_DIR=${WORKDIR}/ens${ens_member}
            OUTPUT_DIR=${MODLDIR}/ens${ens_member}
            mkdir -p ${ENSEMBLE_DIR}
            mkdir -p ${ENSEMBLE_DIR}/restarts
            mkdir ${ENSEMBLE_DIR}/restarts/tile
            mkdir ${ENSEMBLE_DIR}/restarts/vector
            mkdir -p ${OUTPUT_DIR}
            ln -s ${OUTPUT_DIR} ${ENSEMBLE_DIR}/noahmp_output
        done
    else
        mkdir ${WORKDIR}/restarts
        mkdir ${WORKDIR}/restarts/tile
        mkdir ${WORKDIR}/restarts/vector
        ln -s ${MODLDIR} ${WORKDIR}/noahmp_output
    fi

    # substringing to get yr, mon, day, hr info
    export YYYY=`echo $THISDATE | cut -c1-4`
    export MM=`echo $THISDATE | cut -c5-6`
    export DD=`echo $THISDATE | cut -c7-8`
    export HH=`echo $THISDATE | cut -c9-10`

    # for each ensemble member
    for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
    do
        if [ $do_ens == "YES" ]; then
            ens_member=${ens_list[$ensemble_count]}
            ENSEMBLE_DIR=${WORKDIR}/ens${ens_member}
            restart_anal_id=.ens${ens_member}_anal
            restart_back_id=.ens${ens_member}_back
            namelist_file=${CYCLEDIR}/template.ens.ufs-noahMP.namelist.gswp3
        else
            ENSEMBLE_DIR=${WORKDIR}
            restart_anal_id='_anal'
            restart_back_id='_back'
            namelist_file=${CYCLEDIR}/template.ufs-noahMP.namelist.gswp3
        fi

        cd ${ENSEMBLE_DIR}

        # copy initial restart
        src_restart=${SAVEDIR}/vector/ufs_land_restart${restart_back_id}.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
        cp ${src_restart} ${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc

        # update model namelist 
        cp  ${namelist_file}  ufs-land.namelist

        sed -i -e "s/XXYYYY/${YYYY}/g" ufs-land.namelist 
        sed -i -e "s/XXMM/${MM}/g" ufs-land.namelist
        sed -i -e "s/XXDD/${DD}/g" ufs-land.namelist
        sed -i -e "s/XXHH/${HH}/g" ufs-land.namelist

        # Match the variable names in forcing files to those in land drivers for the namelist
        if [ $do_ens == "YES" ]; then
            for (( variable_count=0; variable_count<variable_size; variable_count++ ))
            do
                vname_proxy=USER_${frc_in_list[$variable_count]}
                vname_in_file=${frc_in_file[$variable_count]}
                sed -i -e "s/${vname_proxy}/${vname_in_file}${ens_member}/g" ufs-land.namelist
            done
        fi
     
        if [ $do_jedi == "YES" ]; then  # do DA

            # update vec2tile and tile2vec namelists
            cp  ${CYCLEDIR}/template.vector2tile vector2tile.namelist

            sed -i -e "s/XXYYYY/${YYYY}/g" vector2tile.namelist
            sed -i -e "s/XXMM/${MM}/g" vector2tile.namelist
            sed -i -e "s/XXDD/${DD}/g" vector2tile.namelist
            sed -i -e "s/XXHH/${HH}/g" vector2tile.namelist

            cp  ${CYCLEDIR}/template.tile2vector tile2vector.namelist

            sed -i -e "s/XXYYYY/${YYYY}/g" tile2vector.namelist
            sed -i -e "s/XXMM/${MM}/g" tile2vector.namelist
            sed -i -e "s/XXDD/${DD}/g" tile2vector.namelist
            sed -i -e "s/XXHH/${HH}/g" tile2vector.namelist

            # submit vec2tile 
            echo '************************************************'
            echo 'calling vector2tile' 
            $vec2tileexec vector2tile.namelist
            if [[ $? != 0 ]]; then
                echo "vec2tile failed"
                exit 
            fi
            # add coupler.res file
            cres_file=${ENSEMBLE_DIR}/restarts/tile/${YYYY}${MM}${DD}.${HH}0000.coupler.res
            cp  ${CYCLEDIR}/template.coupler.res $cres_file

            sed -i -e "s/XXYYYY/${YYYY}/g" $cres_file
            sed -i -e "s/XXMM/${MM}/g" $cres_file
            sed -i -e "s/XXDD/${DD}/g" $cres_file

            # submit snow DA 
            echo '************************************************'
            echo 'calling snow DA'
            export THISDATE
            $DAscript
            if [[ $? != 0 ]]; then
                echo "land DA script failed"
                exit
            fi  # submit tile2vec

            echo '************************************************'
            echo 'calling tile2vector' 
            $vec2tileexec tile2vector.namelist
            if [[ $? != 0 ]]; then
                echo "tile2vector failed"
                exit 
            fi

            # save analysis restart
            src_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
            cp ${src_restart} ${SAVEDIR}/vector/ufs_land_restart${restart_anal_id}.${YYYY}-${MM}-${DD}_${HH}-00-00.nc
        fi # DA step

        # submit model
        echo '************************************************'
        if [ $do_ens == "YES" ]; then
            echo 'calling model for ensemble member '${ens_member}
        else
            echo 'calling model'
        fi
        $LSMexec
# no error codes on exit from model, check for restart below instead
#    if [[ $? != 0 ]]; then
#        echo "model failed"
#        exit 
#    fi

        NEXTDATE=`${incdate} $THISDATE 24`
        CUR_YYYY=`echo $NEXTDATE | cut -c1-4`
        CUR_MM=`echo $NEXTDATE | cut -c5-6`
        CUR_DD=`echo $NEXTDATE | cut -c7-8`
        CUR_HH=`echo $NEXTDATE | cut -c9-10`

        src_restart=${ENSEMBLE_DIR}/restarts/vector/ufs_land_restart.${CUR_YYYY}-${CUR_MM}-${CUR_DD}_${CUR_HH}-00-00.nc
        if [[ -e ${src_restart} ]]; then
           cp ${src_restart} ${SAVEDIR}/vector/ufs_land_restart${restart_back_id}.${CUR_YYYY}-${CUR_MM}-${CUR_DD}_${CUR_HH}-00-00.nc
           if [ $do_ens == "YES" ]; then
               echo "Finished job number, ${date_count},for ensemble member: ${ens_member}, for date: ${THISDATE}" >> $logfile
           else
               echo "Finished job number, ${date_count}, for date: ${THISDATE}" >> $logfile
           fi
        else
           echo "Something is wrong, probably the model, exiting" 
           exit
        fi
    done
    wait

    THISDATE=`${incdate} $THISDATE 24`
    date_count=$((date_count+1))

done

# resubmit
if [ $THISDATE -lt $ENDDATE ]; then
    echo "export STARTDATE=${THISDATE}" > ${analdate}
    echo "export ENDDATE=${ENDDATE}" >> ${analdate}
    cd ${CYCLEDIR}
    rm -rf ${WORKDIR}
    sbatch ${CYCLEDIR}/submit_cycle_ens.sh
fi

