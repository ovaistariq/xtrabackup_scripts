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
tmp_log=/tmp/backups-deletion-${backup_date}.log

RET_DELETION_SUCCESS=0

# Import common function
source ${backup_script_root}/functions.sh

vlog "-- Starting to delete backups older than $backup_retention_days days"
find_cmd="find $backup_root -name xtrabackup_checkpoints -type f -mtime +${backup_retention_days} -daystart"
for path in $($find_cmd)
do
    dir_name=$(dirname $path)

    vlog "- Deleting backup $dir_name"
    rm -rf $dir_name
done

vlog "-- Backups deleted successfully"

## Send an email that backup deletion successfully
send_mail $RET_DELETION_SUCCESS "BACKUPS DELETION"
rm -f $tmp_log

