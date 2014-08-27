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

# Acquire a lock. This is needed where we don't want to have more than one
# instance of the script running at the same time.
function acquire_lock() {
    touch $pid_file
    echo $pid > $pid_file
}

# Release the lock. This is to be done when the script exits.
function release_lock() {
    # Delete the PID file only if I created it, i.e. when it has my PID in it
    if [[ -f $pid_file ]] &&  (( $(grep -c $pid $pid_file) > 0 ))
    then
        rm -f $pid_file
    fi
}

# This checks to see if a lock file is valid or not. It has many safety
# measures such as checking if the pid file is non-empty or the pid in 
# the pid-file is a valid pid for our purposes.
function lock_exists() {
    # PID lock file does not exist
    if [[ ! -e $pid_file ]]
    then
        echo false
        exit
    fi

    # PID lock file is empty so its fine to disregard the PID
    pid=$(cat $pid_file)
    if [[ $pid == "" ]]
    then
        echo false
        exit
    fi

    # PID is present in the lock file, we now need to verify if its a valid PID
    proc_dir=/proc/${pid}
    if [[ ! -d $proc_dir ]]
    then
        echo false
        exit
    fi
      
    if [[ ! -e /proc/${pid}/cmdline ]] || (( $(grep -c "$backup_script_path" /proc/${pid}/cmdline) < 1 ))
    then
        echo false
        exit
    fi

    echo true
    exit
}

# Append timestamps to log entries.
function vlog() {
    datetime=$(date "+%Y-%m-%d %H:%M:%S")
    msg="[${datetime}] $1"

    echo $msg | tee -a $tmp_log
}

# Display error message on the command-line and exit the script
function display_error_n_exit() {
    error_msg=$1
    echo "ERROR: $error_msg"
    exit $ERR_INCORRECT_CMDLINE_ARGS
}

# Cleanup tasks to perform after a backup run has been done. This includes
# cleanup tasks both for backups that are successfull or that failed.
function cleanup_after_backup() {
    backup_status=$1

    if [[ $is_full_backup ]]
    then
        backup_dir=$backup_full_dir
    else
        backup_dir=$backup_incremental_dir
    fi

    if (( $backup_status == $ERR_FAILED_BACKUP ))
    then
        rm -rf $backup_dir
    fi

    rm -f $tmp_log
}

# Send email
function send_mail() {
    backup_status=$1
    script_type=$2 # is it a backup or a prepare script
    success_code=0
    hostname=$(hostname -f)

    if (( $backup_status != $success_code ))
    then
        mail_subject="$script_type FAILED ON $hostname"
    else
        mail_subject="$script_type SUCCESSFUL ON $hostname"
    fi

    mail -r $mail_from -s "$mail_subject" "$mail_recipients" < $tmp_log
}

# Calculate how much memory can be used for preparing the backup
function get_memory_available_for_backup_prepare() {
    prepare_memory=$(/usr/bin/free -g | /bin/awk '/buffers\/cache/ {printf "%d\n", $4*0.25}')

    echo $prepare_memory
    return 0
}

