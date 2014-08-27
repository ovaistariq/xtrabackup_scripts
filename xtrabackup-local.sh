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

backup_date=$(date +%Y_%m_%d-%H_%M_%S)
backup_full_dir=${backup_root}/full/${backup_date}
backup_incremental_dir=${backup_root}/incremental/${backup_date}

backup_log=${backup_log_root}/innobackup-${backup_date}.backup.log
tmp_log=/tmp/backup-${backup_date}.log

backup_script_path=${backup_script_root}/$(basename $0)
pid_file=/var/run/$(basename $0 .sh).pid
pid=$$

## Directories setup
mkdir -p $backup_log_root

## Commands setup
innobackupex_cmd=/usr/bin/innobackupex
qpress_cmd=/usr/bin/qpress

## Error codes and return codes
ERR_INCORRECT_CMDLINE_ARGS=50
ERR_ANOTHER_BACKUP_INSTANCE_RUNNING=51
ERR_FAILED_BACKUP=52
RET_BACKUP_SUCCESS=0

# Command line argument processing
OPT_ARGS=":fi"
while getopts "$OPT_ARGS" opt
do  
    case $opt in
        f) is_full_backup=true
        ;;
        i) is_incremental_backup=true
        ;;
    esac
done

# Import common function
source ${backup_script_root}/functions.sh

# Custom functions needed by this script
function do_full_backup() {
    backup_archive=${backup_full_dir}/backup.xbstream.qp

    mkdir -p $backup_full_dir
    
    vlog "-- BACKING up to $backup_archive"
    backup_params="--user=$mysql_user --password=$mysql_password --slave-info --stream=xbstream $backup_full_dir --extra-lsndir=${backup_full_dir}"

    local status=0
    $innobackupex_cmd $backup_params 2> $backup_log | $qpress_cmd -T${num_encryption_threads}io $backup_archive > $backup_archive

    if (( $(tail -1 $backup_log | grep -c 'innobackupex: completed OK!') != 1 ))
    then
        status=1
    else
        touch ${backup_full_dir}/${verification_status_check_filename}
    fi

    return $status
}

function do_incremental_backup() {
    backup_archive=${backup_incremental_dir}/backup.xbstream.qp

    mkdir -p $backup_incremental_dir

    # Calculate the last LSN of the latest backup
    find_cmd="find ${backup_root} -type f -name xtrabackup_checkpoints -print0"
    latest_backup_checkpoint_file=$($find_cmd | xargs -r0 stat -c %y\ %n | sort -r | awk '{print $4}' | head -1)
    lsn_last_backup=$(grep to_lsn $latest_backup_checkpoint_file | awk -F'=' '{printf "%d", $2}')

    vlog "-- BACKING up to $backup_archive"
    backup_params="--user=$mysql_user --password=$mysql_password --incremental --incremental-lsn=${lsn_last_backup} --slave-info --stream=xbstream $backup_incremental_dir --extra-lsndir=${backup_incremental_dir}"
    local status=0
    $innobackupex_cmd $backup_params 2> $backup_log | $qpress_cmd -T${num_encryption_threads}io $backup_archive > $backup_archive

    if (( $(tail -1 $backup_log | grep -c 'innobackupex: completed OK!') != 1 ))
    then
        status=1
    else
        touch ${backup_incremental_dir}/${verification_status_check_filename}
    fi

    return $status
}

# Trap exit signals
trap release_lock EXIT SIGINT SIGTERM

# Both full and incremental types of backups cannot be specified together
if [[ $is_full_backup == true && $is_incremental_backup == true ]]
then 
    display_error_n_exit "You cannot specify both full back and incremental backup"
fi

# At least one type of backup, full or incremental should be selected
if [[ -z $is_full_backup && -z $is_incremental_backup ]]
then 
    display_error_n_exit "Please specify at least one type of backup"
fi

# Lock handling to make sure only one instance of backup is running at a time
# If a lock file exists then we exit from here because a backup is already running
if [[ $(lock_exists) == true ]]
then
    display_error_n_exit "Exiting because another backup instance is running"
fi

# Acquire the lock so that another instance of backup does not startup
acquire_lock

# Do the actual backup stuff
if [[ $is_full_backup ]]
then
    do_full_backup | tee -a $tmp_log
else
    do_incremental_backup | tee -a $tmp_log
fi

# If backup fails we delete the failed backup archive and exit here
if (( $? != 0 ))
then 
    if [[ $is_full_backup ]]
    then
        vlog "-- BACKUP (full) failed, check $backup_log"
    else
        vlog "-- BACKUP (incremental) failed, check $backup_log"
    fi

    send_mail $ERR_FAILED_BACKUP "BACKUP"
    cleanup_after_backup $ERR_FAILED_BACKUP
        
    exit $ERR_FAILED_BACKUP
fi

vlog "-- BACKUP finished successfully, backup log is available at $backup_log"

## Send an email that backup completed successfully
send_mail $RET_BACKUP_SUCCESS "BACKUP"
cleanup_after_backup $RET_BACKUP_SUCCESS

# Release the lock so that another instance of backup can be run
release_lock

