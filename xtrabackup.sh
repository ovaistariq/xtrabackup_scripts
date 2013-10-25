#!/usr/bin/env bash

# (c) 2013, Ovais Tariq <ovaistariq@gmail.com>
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

backup_date=$(date +%F)
backup_root="/backups/data"
backup_log_root="/backups/logs"
backup_archive="${backup_root}/${backup_date}-backup.tar.gz"
backup_log="${backup_log_root}/innobackupex.backup.log"
backup_tmp_log="/tmp/backup-${backup_date}.log"

innobackupex_cmd="/usr/bin/innobackupex"
gzip_cmd="/bin/gzip"
verification_cmd="xtrabackup_verify_helper.sh"
mail_cmd="/bin/mail"
hostname_cmd="/bin/hostname"
defaults_file="/root/.my.cnf"
log_copy_interval_ms=0
mail_recipients="ovaistariq@gmail.com"

# Error codes and return codes
ERR_FAILED_BACKUP=51
RET_BACKUP_SUCCESS=0

function vlog() {
        datetime=$(date "+%Y-%m-%d %H:%M:%S")
        msg="[${datetime}] $1"

        echo $msg | tee -a $backup_tmp_log
}

function cleanup() {
        backup_status=$1
        if (( $backup_status == $ERR_FAILED_BACKUP ))
        then
                rm -f $backup_archive
        fi

        rm -f $backup_tmp_log
}

function send_mail() {
        backup_status=$1
        hostname=$($hostname_cmd)

        if (( $backup_status == $ERR_FAILED_BACKUP ))
        then
                mail_subject="BACKUP FAILED ON $hostname"
        else
                mail_subject="BACKUP SUCCESSFUL ON $hostname"
        fi

        mail -s "$mail_subject" "$mail_recipients" < $backup_tmp_log
}

vlog "-- BACKING up to $backup_archive"
$innobackupex_cmd --defaults-extra-file=$defaults_file --slave-info --log-copy-interval=$log_copy_interval_ms --stream=tar /backups 2>> $backup_log | $gzip_cmd - > $backup_archive

## If backup fails we delete the failed backup archive and exit here
if (( $(tail -1 $backup_log | grep -c 'innobackupex: completed OK!') != 1 ))
then 
        vlog "-- BACKUP failed, check $backup_log"

        send_mail $ERR_FAILED_BACKUP
        cleanup $ERR_FAILED_BACKUP
        
        exit 1
fi

vlog "-- BACKUP finished successfully, backup log is available at $backup_log"

## Run backup verification
$verification_cmd $backup_archive | tee -a $backup_tmp_log
verification_retcode=${PIPESTATUS[0]}

# We exit this script if verification fails because we do not want to recycle the past
# healthy backups in such a case
if (($verification_retcode != 0))
then
        send_mail $ERR_FAILED_BACKUP
        cleanup $ERR_FAILED_BACKUP

        exit $verification_retcode
fi

## Recycle the backups
vlog "-- RECYCLING old backups"
find /backups/data -type f -mtime +1 | xargs /bin/rm -f

vlog "-- RECYCLING of backups completed successfully"

vlog "-- ALL DONE"

## Send an email that backup completed successfully
send_mail $RET_BACKUP_SUCCESS
cleanup $RET_BACKUP_SUCCESS

