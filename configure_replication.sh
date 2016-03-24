#!/bin/bash -u

# Configuration options
# The host that will be configured as the slave
slave_host=

# Is the backup_source_host a master?
# These variables are used to setup the correct master host.
# If the backup_source_host is the same as mysql_master_host, then binlog 
# coordinates from the file xtrabackup_binlog_info are used to setup 
# replication.
# If the backup_source_host is different from mysql_master_host, then binlog 
# cooridnates from the file xtrabackup_slave_info is used to setup replication.
# By default backup_source_host is implied to be a slave
backup_source_host=
mysql_master_host=

# The MySQL data directory on slave_host
slave_datadir=

# MySQL user credentials that will be used to execute MySQL queries
mysql_username=
mysql_password=

# Replication MySQL users that will be used to setup replication
mysql_repl_username=
mysql_repl_password=

# Setup tools
mysqladmin_bin="/usr/bin/mysqladmin"
mysql_bin="/usr/bin/mysql"

# Function definitions
function vlog() {
    datetime=$(date "+%Y-%m-%d %H:%M:%S")
    msg="[${datetime}] $1"

    echo ${msg}
}

function show_error_n_exit() {
    error_msg=$1
    echo "ERROR: ${error_msg}"
    exit 1
}


function cleanup() {
    vlog "Doing cleanup before exiting"

    #TODO: add code to cleanup any running child processes
}

function test_mysql_access() {
#    set -x

    local mysqladmin_args="--host=localhost --user=${mysql_username} --password=${mysql_password}"
    local is_mysqld_alive=$(ssh ${slave_host} "${mysqladmin_bin} ${mysqladmin_args} ping" 2> /dev/null)

    if [[ "${is_mysqld_alive}" != "mysqld is alive" ]]; then
        echo 2003 # MySQL error code for connection error
    else
        echo 0
    fi
#    set +x
}

function setup_replication() {
#    set -x

    local binlog_filename=
    local binlog_position=
    local change_master_sql=

    local repl_master=$(ssh -q ${mysql_master_host} "/bin/hostname")
    local mysql_args="--user=${mysql_username} --password=${mysql_password}"

    if [[ "${backup_source_host}" == "${mysql_master_host}" ]]; then
    	binlog_filename=$(ssh -q ${slave_host} "cut -f 1 ${slave_datadir}/xtrabackup_binlog_info")
    	binlog_position=$(ssh -q ${slave_host} "cut -f 2 ${slave_datadir}/xtrabackup_binlog_info")
    else
    	binlog_filename=$(ssh -q ${slave_host} "cut -d \"'\" -f 2 ${slave_datadir}/xtrabackup_slave_info")
    	binlog_position=$(ssh -q ${slave_host} "cut -d \"=\" -f 3 ${slave_datadir}/xtrabackup_slave_info")
    fi

    if [[ "${binlog_filename}" == "" ]] || [[ "${binlog_position}" == "" ]] || [[ "${repl_master}" == "" ]]; then
        echo "Binary log coordinates could not be parsed from either xtrabackup_binlog_info or the xtrabackup_slave_info file. Make sure the file exists and is not empty"
        exit 2014
    fi

    ssh ${slave_host} "${mysql_bin} ${mysql_args} -e \"STOP SLAVE\""

    change_master_sql="CHANGE MASTER TO MASTER_HOST='${repl_master}', MASTER_LOG_FILE='${binlog_filename}', MASTER_LOG_POS=${binlog_position}"
    vlog "Executing ${change_master_sql}"

    ssh ${slave_host} "${mysql_bin} ${mysql_args} -e \"${change_master_sql}, MASTER_USER='${mysql_repl_username}', MASTER_PASSWORD='${mysql_repl_password}'\""

    if (( $? != 0 )); then
        echo "Failed to execute CHANGE MASTER"
        exit 22
    fi

    ssh ${slave_host} "${mysql_bin} ${mysql_args} -e \"START SLAVE\""

    sleep 5
    vlog "Replication setup successfully"

    vlog "Current slave status:"
    ssh ${slave_host} "${mysql_bin} ${mysql_args} -e \"SHOW SLAVE STATUS\G\""

#    set +x
}

# Usage info
function show_help() {
cat << EOF
Usage: ${0##*/} --backup-source-host BACKUP_SOURCE_HOST --mysql-master-host MySQL_MASTER_HOST --slave-host SLAVE_HOST --slave-datadir SLAVE_DATADIR --mysql-user MYSQL_USER --mysql-password MYSQL_PASSWORD --mysql-repl-user MYSQL_REPL_USER --mysql-repl-password MYSQL_REPL_PASSWD [options]
Configure replication on SLAVE_HOST with MySQL_MASTER_HOST as the master and using MYSQL_REPL_USER and MYSQL_REPL_PASSWD as replication user credentials

Options:

    --help                                  display this help and exit
    --backup-source-host BACKUP_SOURCE_HOST the host that was the source of the
                                            backup
    --mysql-master-host MySQL_MASTER_HOST   the host that is to be configured
                                            as the master of the SLAVE_HOST
    --slave-host SLAVE_HOST                 the host that has to be setup as
                                            the slave
    --slave-datadir SLAVE_DATADIR           the MySQL datadir on the slave
    --mysql-user MYSQL_USER                 the MySQL user that would be used
                                            to execute CHANGE MASTER qeury
    --mysql-password MYSQL_PASSWORD         the MySQL user password
    --mysql-repl-user MYSQL_REPL_USER       the MySQL username that would by
                                            replication
    --mysql-repl-password MYSQL_REPL_PASSWD the MySQL replication user password
EOF
}

function show_help_and_exit() {
    show_help >&2
    exit 22 # Invalid parameters
}

# Command line processing
OPTS=$(getopt -o hb:m:s:d:u:p:U:P: --long help,backup-source-host:,mysql-master-host:,slave-host:,slave-datadir:,mysql-user:,mysql-password:,mysql-repl-user:,mysql-repl-password: -n 'configure_replication.sh' -- "$@")
[ $? != 0 ] && show_help_and_exit

eval set -- "$OPTS"

while true; do
  case "$1" in
    -b | --backup-source-host )
                                backup_source_host="$2";
                                shift; shift
                                ;;
    -m | --mysql-master-host )
                                mysql_master_host="$2";
                                shift; shift
                                ;;
    -s | --slave-host )
                                slave_host="$2";
                                shift; shift
                                ;;
    -d | --slave-datadir )
                                slave_datadir="$2";
                                shift; shift
                                ;;
    -u | --mysql-user )
                                mysql_username="$2";
                                shift; shift
                                ;;
    -p | --mysql-password )
                                mysql_password="$2";
                                shift; shift
                                ;;
    -U | --mysql-repl-user )
                                mysql_repl_username="$2";
                                shift; shift
                                ;;
    -P | --mysql-repl-password )
                                mysql_repl_password="$2";
                                shift; shift
                                ;;
    -h | --help )
                                show_help >&2
                                exit 1
                                ;;
    -- )                        shift; break
                                ;;
    * )
                                show_help >&2
                                exit 1
                                ;;
  esac
done


# Sanity checking of command line parameters
[[ -z ${backup_source_host} ]] && show_help_and_exit >&2

[[ -z ${mysql_master_host} ]] && show_help_and_exit >&2

[[ -z ${slave_host} ]] && show_help_and_exit >&2

ssh -q ${slave_host} "exit"
(( $? != 0 )) && show_error_n_exit "Could not SSH into ${slave_host}"

[[ -z ${slave_datadir} ]] && show_help_and_exit >&2

[[ -z ${mysql_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_password} ]] && show_help_and_exit >&2

[[ -z ${mysql_repl_username} ]] && show_help_and_exit >&2

[[ -z ${mysql_repl_password} ]] && show_help_and_exit >&2

# Test that all tools are available
for tool_bin in ${mysqladmin_bin} ${mysql_bin}; do
    if (( $(ssh ${slave_host} "which $tool_bin" &> /dev/null; echo $?) != 0 )); then
        echo "Can't find $tool_bin on ${slave_host}"
        exit 22 # OS error code  22:  Invalid argument
    fi
done

# Test that MySQL credentials are correct
vlog "Testing MySQL access on ${slave_host}"
if (( $(test_mysql_access) != 0 )); then
    echo "Could not connect to MySQL"
    exit 2003
fi

# Do the actual stuff
trap cleanup HUP PIPE INT TERM

# Configure replication
setup_replication

# Do the cleanup
cleanup

exit 0
