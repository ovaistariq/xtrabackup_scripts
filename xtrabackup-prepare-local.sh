#!/usr/bin/env bash

# (c) 2014, Ovais Tariq <ovaistariq@gmail.com>
#
# This file is part of https://github.com/ovaistariq/xtrabackup_scripts
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## Configuration options
backup_script_root=$(dirname $(readlink -f $0))
source ${backup_script_root}/backup.conf

## Commands setup
innobackupex_cmd=/usr/bin/innobackupex
qpress_cmd=/usr/bin/qpress

## Error codes and return codes
ERR_INCORRECT_CMDLINE_ARGS=50
ERR_FAILED_BACKUP_DECOMPRESSION=51
ERR_FAILED_BACKUP_PREPARE=52
ERR_INCREMENTAL_BASE_BACKUP=53
RET_PREPARE_SUCCESS=0

# Command line option parsing
OPT_ARGS=":s:d:"
while getopts "$OPT_ARGS" opt
do
    case $opt in
        s) backup_dir_to_prepare=$OPTARG
        ;;
        d) prepare_destination_dir=$OPTARG
        ;;
    esac
done

# Canonicalize the path
backup_dir_to_prepare=$(readlink -f $backup_dir_to_prepare)
prepare_destination_dir=$(readlink -f $prepare_destination_dir)

# Sanity checks to check if paths supplied as arguments exist
if [[ -z $backup_dir_to_prepare ]] || [[ ! -d $backup_dir_to_prepare ]]
then
    display_error_n_exit "The path to backup directory to prepare is missing or does not exist"
fi

if [[ -z $prepare_destination_dir ]] || [[ ! -d $prepare_destination_dir ]]
then
    display_error_n_exit "The path to directory to prepare the backup into is missing or does not exist"
fi

# Sanitize the backup directory name
backup_timestamp=$(basename $backup_dir_to_prepare)
backup_dir_to_prepare=$(find $backup_root -name $backup_timestamp -type d)
prepare_log=${backup_log_root}/innobackup-${backup_timestamp}.prepare.log
tmp_log=/tmp/prepare-${backup_timestamp}.log

# Import common function
source ${backup_script_root}/functions.sh

# Custom functions needed by this script
function prepare_single_backup() {
    local backup_source_dir=$1
    local backup_destination_dir=$2
    local backup_uncompress_to_dir=$3
    local do_uncompression=$4
    local extra_flags=$5

    if [[ $extra_flags == false ]]
    then
        extra_flags=""
    fi

    # Decompress the backup first
    if [[ $do_uncompression == true ]]
    then
        # We might not want to decompress the backup in some cases, for example 
        # in case of incremental backups where we decompress it to a temporary directory
        ${qpress_cmd} -do ${backup_source_dir}/backup.xbstream.qp | xbstream -x - -C ${backup_uncompress_to_dir}

        qpress_xbstream_ret_code=$?
        if (( $qpress_xbstream_ret_code != 0 ))
        then
            vlog "- Decompressing/unarchiving backup failed"
            return $ERR_FAILED_BACKUP_DECOMPRESSION
        fi
    fi

    local prepare_memory=$(get_memory_available_for_backup_prepare)
    vlog "- Starting innobackupex apply-log phase with ${prepare_memory}G memory"
    
    cmd="$innobackupex_cmd --apply-log --use-memory=${prepare_memory}G $extra_flags $backup_destination_dir"
    eval "$cmd" 2>> $prepare_log

    prepare_return_code=$?
    if (( $prepare_return_code != 0 ))
    then
        vlog "- PREPARING failed, check $prepare_log"
        return $ERR_FAILED_BACKUP_PREPARE
    fi

    return 0
}

function prepare_full_backup() {
    local backup_uncompress_to_dir=$prepare_destination_dir
    local extra_flags=false
    local do_uncompression=true

    vlog "-- PREPARING FULL backup $backup_dir_to_prepare into $prepare_destination_dir"

    # Clean up the directory to prepare into
    rm -rf ${prepare_destination_dir}/*

    # Reset the prepare log
    > $prepare_log

    # Prepare the backup
    prepare_single_backup $backup_dir_to_prepare $prepare_destination_dir $backup_uncompress_to_dir $do_uncompression $extra_flags

    return $?
}

# Returns the full backup which is the base of the incremental backup
function find_incremental_base_backup() {
    base_backup_dir=false
    
    IFS_old=$IFS
    IFS=$'\n'
    for dir in $(find $backup_root -name xtrabackup_checkpoints -type f -print0 | xargs -r0 stat -c %y\ %n | sort)
    do
        path=$(dirname $(echo $dir | awk '{print $4}'))
        if [[ $path == *full* ]]
        then
            base_backup_dir=$path
        fi

        if [[ $path == *${backup_dir_to_prepare}* ]]
        then
            break
        fi
    done
    IFS=$IFS_old

    if [[ $base_backup_dir == false ]]
    then
        echo false
        exit 1
    fi

    echo $base_backup_dir
    exit 0
}

function prepare_incremental_backup() {
    local prepare_ret_code=0
    local do_uncompression=true
    local incremental_tmp_dir=${prepare_destination_dir}/__incremental_tmp
    local extra_flags="--redo-only"

    vlog "-- PREPARING INCREMENTAL backup $backup_dir_to_prepare into $prepare_destination_dir"

    incremental_base_backup=$(find_incremental_base_backup)
    if [[ $incremental_base_backup == false ]]
    then
        vlog "- Failed to find the base backup for this incremental"
        return $ERR_INCREMENTAL_BASE_BACKUP
    fi

    # Reset the prepare log
    > $prepare_log

    IFS_old=$IFS
    IFS=$'\n'
    prepare_backup=false

    for dir in $(find $backup_root -name xtrabackup_checkpoints -type f -print0 | xargs -r0 stat -c %y\ %n | sort)
    do
        path=$(dirname $(echo $dir | awk '{print $4}'))

        # We find first the starting point to start preparing the backups from
        # i.e. its the first full backup before this incremental which is known
        # as the base backup for this incremental
        if [[ $path == *${incremental_base_backup}* ]]
        then
            prepare_backup=true
            vlog "- Preparing the base backup of the incremental $path"

            # Clean up the directory to prepare into
            rm -rf ${prepare_destination_dir}/*

            # Prepare the backup
            prepare_single_backup $path $prepare_destination_dir $prepare_destination_dir $do_uncompression $extra_flags
            prepare_ret_code=$?

            # If preparation fails we exit from here
            if [[ $prepare_ret_code != 0 ]]
            then
                return $prepare_ret_code
            fi

            # We continue on to the next backup in series to prepare
            continue
        fi

        # If the prepare_backup flag is set which means we need to prepare the backup
        if [[ $prepare_backup == true ]]
        then
            vlog "- Preparing the incremental $path"

            # We extract the incremental backup to a temporary directory
            rm -rf $incremental_tmp_dir
            mkdir -p $incremental_tmp_dir

            extra_flags="--redo-only --incremental-dir=$incremental_tmp_dir"
            prepare_single_backup $path $prepare_destination_dir $incremental_tmp_dir $do_uncompression $extra_flags
            prepare_ret_code=$?

            # If preparation fails we exit from here
            if [[ $prepare_ret_code != 0 ]]
            then
                return $prepare_ret_code
            fi
        fi

        # We have reached the incremental directory upto which we wish to prepare so 
        # now we do the final apply-log and stop processing any further backups
        if [[ $path == *${backup_dir_to_prepare}* ]]
        then
            vlog "- Doing the final --apply-log phase on $prepare_destination_dir"

            # Clear up the incremental temporary directory
            rm -rf $incremental_tmp_dir

            # Do the final apply-log
            extra_flags=false
            do_uncompression=false
            prepare_single_backup $path $prepare_destination_dir $prepare_destination_dir $do_uncompression $extra_flags
            prepare_ret_code=$?

            # If preparation fails we exit from here
            if [[ $prepare_ret_code != 0 ]]
            then
                return $prepare_ret_code
            fi

            # We break from the loop because we do not want to process any further backups
            break
        fi
    done
    IFS=$IFS_old

    return 0
}


# Find out the type of backup, i.e. is it incremental or full
if [[ $backup_dir_to_prepare == *incremental* ]]
then
    prepare_incremental_backup | tee -a $tmp_log
else
    prepare_full_backup | tee -a $tmp_log
fi

# If backup preparation fails we delete the contents of the directory where
# backup was being prepared into
prepare_ret_code=$?
if (( $prepare_ret_code != 0 ))
then
    vlog "-- BACKUP PREPARATION failed, check $prepare_log"

    send_mail $prepare_ret_code "PREPARE"
    rm -rf ${prepare_destination_dir}/*
    rm -f $tmp_log

    exit $prepare_ret_code
fi

vlog "-- BACKUP PREPARED successfully, prepare log is available at $prepare_log"

## Send an email that prepare completed successfully
send_mail $RET_PREPARE_SUCCESS "PREPARE"
rm -f $tmp_log

