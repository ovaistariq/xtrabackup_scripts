#!/bin/bash

## Initialize variables
backup_root=/backups/data
backup_log_root=/backups/logs
backup_archive=$1
db_to_verify=test

## Setup commands used
innobackupex_cmd="/usr/bin/innobackupex"
tar_cmd="/bin/tar"
mysqld_cmd="/usr/sbin/mysqld"
mysqladmin_cmd="/usr/bin/mysqladmin"
mysql_cmd="/usr/bin/mysql"
mysqlcheck_cmd="/usr/bin/mysqlcheck"

## Function definitions
function vlog() {
        datetime=$(date "+%Y-%m-%d %H:%M:%S")
        echo "[${datetime}] $1"
}

function remove_backupdir() {
        vlog "- Removing unarchived backup directory $1"
        rm -rf $1
}

## Sanity checks
if [[ -z $backup_archive ]]
then
        vlog "Error: backup archive name was not passed"
        exit 1
fi

if [[ ! -e $backup_archive ]]
then
        vlog "Error: the backup file does not exist"
        exit 1
fi

backup_dir=${backup_root}/$(basename $backup_archive ".tar.gz")
if [[ -e $backup_dir ]]
then
        vlog "Error: the directory to unarchive to, already exists"
        exit 1
fi

## Set variables relative to the backup directory
prepare_log="${backup_log_root}/innobackupex.prepare.log"
verify_error_log="${backup_log_root}/mysqld_verify.log"
backup_my_cnf="${backup_dir}/backup-my.cnf"
verify_pid="${backup_dir}/mysqld_verify.pid"
verify_socket="${backup_dir}/mysqld_verify.sock"
verify_datadir="$backup_dir"
mysqlcheck_log="${backup_log_root}/mysqlcheck.log"

## Prepare the directory
mkdir $backup_dir

## Uncompress and Unarchive
vlog "-- UNARCHIVING the backup archive $backup_archive"
$tar_cmd -xzif $backup_archive -C $backup_dir

vlog "-- UNARCHIVING stage finished successfully"

## Prepare the backup
prepare_memory=$(/usr/bin/free -g | /bin/awk '/buffers\/cache/ {printf "%d\n", $4*0.25}')
vlog "-- PREPARING the backup with ${prepare_memory}G of memory"
$innobackupex_cmd --apply-log --use-memory=${prepare_memory}G $backup_dir 2>> $prepare_log

prepare_return_code=$?
if (( $prepare_return_code != 0 ));
then
        vlog "- PREPAREING failed, check $prepare_log"
        remove_backupdir $backup_dir
        exit 1
fi

vlog "-- PREPARING stage finished successfully"

## Verify the backup
verify_innodb_datadir=$(grep innodb_data_file_path $backup_my_cnf | cut -d "=" -f 2)
verify_innodb_log_files_group=$(grep innodb_log_files_in_group $backup_my_cnf | cut -d "=" -f 2)
verify_innodb_log_file_size=$(grep innodb_log_file_size $backup_my_cnf | cut -d "=" -f 2)
vlog "-- VERIFYING the backup"
vlog "- Starting MySQL instance on $verify_datadir"
$mysqld_cmd --no-defaults \
        --user=root \
        --skip-grant-tables \
        --skip-networking \
        --log-error=${verify_error_log} \
        --pid=${verify_pid} \
        --socket=${verify_socket} \
        --datadir=${verify_datadir} \
        --log-slow-queries=0 \
        --skip-slave-start \
        --log=0 \
        --skip-log-warnings \
        --innodb_data_file_path=${verify_innodb_datadir} \
        --innodb_log_files_in_group=${verify_innodb_log_files_group} \
        --innodb_log_file_size=${verify_innodb_log_file_size} >> $verify_error_log 2>&1 &

# Check to see that MySQL has started
mysqld_status=""
while [[ $mysqld_status != "mysqld is alive" ]]
do
        sleep 5
        mysqld_status=$($mysqladmin_cmd ping --socket=${verify_socket} 2> /dev/null)

        # Check if MySQL is still running
        mysqld_running=$(ps ax | grep -F $verify_error_log | grep -v grep | wc -l)
        if (( $mysqld_running < 1 ))
        then
                vlog "- MySQL verification instance seems to have shutdown"
                vlog "- VERIFICATION failed, check $verify_error_log"

                remove_backupdir $backup_dir
                exit 1
        fi
done

vlog "- MySQL verification instance has started"

vlog "- Checking tables in $db_to_verify"
for tbl in $($mysql_cmd --socket=${verify_socket} information_schema -e "SELECT table_name FROM TABLES WHERE table_schema='${db_to_verify}'" -NB)
do
        #echo -n "Checking $tbl ... "
        check_start_time=$(date +%s)
        $mysqlcheck_cmd --socket=${verify_socket} $db_to_verify $tbl >> $mysqlcheck_log 2>&1

        check_end_time=$(date +%s)
        check_duration=$(($check_end_time - $check_start_time))
        #echo -n "took $check_duration seconds ... "

        # We do some throttling here so that we don't disrupt prod traffic during CHECK TABLE runs
        check_delay=$(($check_duration * 10/100))
        #echo "sleeping $check_delay seconds between checks"
        sleep $check_delay
done
        
# Check to see if there were errors during CHECK TABLEs
mysqlcheck_errros=$(grep -c Error $mysqlcheck_log)
if (($mysqlcheck_errros > 0))
then
        vlog "- Error(s) found when checking tables"
        vlog "- VERIFICATION failed, check $verify_error_log"
        exit_code=1
else
        vlog "- No error(s) found during verification"
        vlog "- VERIFICATION SUCCESSFULL"
        exit_code=0
fi

# Now shutdown the test instance and remove the backup dir
vlog "- Shutting down MySQL verification instance"
$mysqladmin_cmd shutdown --socket=${verify_socket}
remove_backupdir $backup_dir

vlog "-- VERIFICATION stage completed successfully"

# Exit with the appropriate error code
exit $exit_code

