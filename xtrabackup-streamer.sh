#!/bin/bash -u

# Configuration options
backup_threads=4
compress_threads=4
decompress_threads=4
nc_port=7777

master_host=
slave_host=
slave_datadir=
test_only=

# Setup temporary directory
tmp_dir=$(mktemp -d)
mkdir -p $tmp_dir

# Setup logs
backup_log="${tmp_dir}/innobackup.backup.log"
prepare_log="${tmp_dir}/innobackup.prepare.log"

# Function definitions
function vlog() {
    datetime=$(date "+%Y-%m-%d %H:%M:%S")
    msg="[${datetime}] $1"

    echo $msg
}

function display_error_n_exit() {
    error_msg=$1     
    echo "ERROR: $error_msg"
    exit 1
}

# Calculate how much memory can be used for preparing the backup
function get_memory_available_for_backup_prepare() {
    prepare_memory=$(ssh -q $slave_host "/usr/bin/free -g" | /bin/awk '/buffers\/cache/ {printf "%dG\n", $4*0.5}')

    echo $prepare_memory
    return 0
}

function get_nc_pid() {
#    set -x
    local port=$1
    local remote_host=$2

    local pid=$(ssh $remote_host "ps -aef" | grep nc | grep -v bash | grep $port | awk '{ print $2 }')
    echo $pid
#    set +x
}

function cleanup_nc() {
    local port=$1
    local remote_host=$2

    local pid=$(get_nc_pid $port $remote_host)
    vlog "Killing nc pid $pid"

    [[ "$pid" != '' && "$pid" != 0 ]] && ssh $remote_host "kill $pid && (kill $pid && kill -9 $pid)" || :
}

function check_pid() {
#    set -x
    local pid=$1
    local remote_host=$2
    [[ "$pid" != 0 && "$pid" != '' ]] && ssh $remote_host "ps -p $pid" >/dev/null 2>&1

    echo $?
#    set +x
}

# waits ~10 seconds for nc to open the port and then reports ready
wait_for_nc()
{
#    set -x
    local port=$1
    local remote_host=$2

    for i in $(seq 1 50)
    do
        ssh $remote_host "netstat -nptl 2>/dev/null" | grep '/nc\s*$' | awk '{ print $4 }' | \
        sed 's/.*://' | grep \^${port}\$ >/dev/null && break
        sleep 0.2
    done

    vlog "ready ${remote_host}:${port}"
#    set +x
}

function setup_remote_directories() {
    vlog "Setting up directories on master and slave"

    # Initialize temp directory on master
    ssh -q $master_host "mkdir -p $tmp_dir"

    # Initialize temp directory on slave
    ssh -q $slave_host "mkdir -p $tmp_dir"

    # Initialize other directories on slave
    ssh -q $slave_host "mkdir -p $slave_datadir; rm -rf $slave_datadir/*"
}

function test_remote_sockets() {
#    set -x

    vlog "Testing remote communication: $master_host <-> $slave_host"

    wait_for_nc $nc_port $slave_host &

    # Create a test socket to test to see if we can create and send to sockets
    ssh $slave_host "nohup bash -c \"($nc_bin -dl $nc_port > ${slave_datadir}/hello.txt) &\" > /dev/null 2>&1"

    wait %% # join wait_for_nc thread

    # check if nc is running, if not then it errored out
    local nc_pid=$(get_nc_pid $nc_port $slave_host)
    (( $(check_pid $nc_pid $slave_host ) != 0 )) && display_error_n_exit "Could not create a socket on $slave_host"

    ssh $master_host "echo 'hello world' | $nc_bin $slave_host $nc_port"
    if [[ $? != 0 ]]
    then
        cleanup_nc $nc_port $slave_host
        display_error_n_exit "Could not connect to remote socket on $slave_host from $master_host"
    fi

    vlog "$master_host <-> $slave_host can communicate on $nc_port"

#    set +x

    exit $?
}

function send_backup_to_slave() {
#    set -x

    qpress_args="-T${decompress_threads}dio"
    xbstream_args="-x -C $slave_datadir"

    # Cleanup old sockets
    vlog "Cleaning up old sockets"
    cleanup_nc $nc_port $slave_host

    wait_for_nc $nc_port $slave_host &

    # Create receiving socket on slave
    ssh $slave_host "nohup bash -c \"($nc_bin -dl $nc_port | $qpress_bin $qpress_args | $xbstream_bin $xbstream_args) &\" > /dev/null 2>&1"

    wait %% # join wait_for_nc thread

    # check if nc is running, if not then it errored out
    local nc_pid=$(get_nc_pid $nc_port $slave_host)
    (( $(check_pid $nc_pid $slave_host ) != 0 )) && display_error_n_exit "Could not create a socket on $slave_host"

    local innobackupex_args="--no-version-check --parallel=${backup_threads} --slave-info --stream=xbstream /tmp"
    local qpress_args="-T${compress_threads}io backup.xbstream.qp"

    vlog "Executing $innobackupex_bin $innobackupex_args on $master_host"
    ssh $master_host "$innobackupex_bin $innobackupex_args 2> $backup_log | $qpress_bin $qpress_args | $nc_bin $slave_host $nc_port"

    # Copy the backup log from the master
    scp $master_host:$backup_log $backup_log &> /dev/null

    if (( $(tail -1 $backup_log | grep -c 'innobackupex: completed OK!') != 1 ))
    then
        cleanup_nc $nc_port $slave_host
        display_error_n_exit "$innobackupex_bin finished with error. Details in log $backup_log"
    fi

    vlog "Backup successfully streamed from $master_host to $slave_host. Details in log $backup_log"

#    set +x
}

function prepare_backup_on_slave() {
#    set -x

    # Prepare the backup on the slave
    local memory_for_prepare_step=$(get_memory_available_for_backup_prepare)
    local innobackupex_args="--no-version-check --apply-log --use-memory=${memory_for_prepare_step} $slave_datadir"

    vlog "Executing $innobackupex_bin $innobackupex_args on $slave_host"
    ssh $slave_host "$innobackupex_bin $innobackupex_args 2> $prepare_log"

    # Copy the prepare log from the slave
    scp $slave_host:$prepare_log $prepare_log &> /dev/null

    if (( $(tail -1 $prepare_log | grep -c 'innobackupex: completed OK!') != 1 ))
    then
        display_error_n_exit "$innobackupex_bin finished with error. Details in log $prepare_log"
    fi

    vlog "Backup successfully prepared on $slave_host. Details in log $prepare_log"

#    set +x
}

# Command line argument processing
OPT_ARGS=":m:s:d:t"
while getopts "$OPT_ARGS" opt
do
    case $opt in
        m) master_host=$OPTARG
        ;;
        s) slave_host=$OPTARG
        ;;
        d) slave_datadir=$OPTARG
        ;;
        t) test_only=true
        ;;
    esac
done

# Setup tools
innobackupex_bin="/usr/bin/innobackupex"
qpress_bin="/usr/bin/qpress"
xbstream_bin="/usr/bin/xbstream"
nc_bin="/usr/bin/nc"

for tool_bin in $innobackupex_bin $qpress_bin $xbstream_bin $nc_bin
do
    for host in $master_host $slave_host
    do
        if (( $(ssh $host "which $tool_bin" &> /dev/null; echo $?) != 0 ))
        then
            echo "Can't find $tool_bin in PATH on $host"
            exit 22 # OS error code  22:  Invalid argument
        fi
    done
done

# If there are parameter errors then exit
[[ -z $master_host ]] && display_error_n_exit "Hostname of the master host not provided"

ssh -q $master_host "exit"
[[ $? != 0 ]] && display_error_n_exit "Could not SSH into $master_host"

[[ -z $slave_host ]] && display_error_n_exit "Hostname of slave host not provided"

ssh -q $slave_host "exit"
[[ $? != 0 ]] && display_error_n_exit "Could not SSH into $slave_host"

[[ -z $slave_datadir ]] && display_error_n_exit "Slave's data directory path not provided"

ssh -q $slave_host "[[ -d $slave_datadir ]]"
[[ $? != 0 ]] && display_error_n_exit "Could not find directory $slave_datadir on the slave $slave_host"


# Test if nc based sockets work to/from master to slave
[[ ! -z $test_only ]] && test_remote_sockets


# Do the actual stuff
trap cleanup_nc HUP PIPE INT TERM

# Setup the directories needed on the master and slave
vlog "Setting up temporary directories on master and slave"

for host in "$master_host" "$slave_host"
do
    ssh -q $host "mkdir -p $tmp_dir"
done

# Send backup to slave from master
send_backup_to_slave

# Prepare the backup on the slave
prepare_backup_on_slave

# Cleanup directories on master and slave
for host in "$master_host" "$slave_host"
do
    ssh -q $host "rm -rf $tmp_dir"
done

echo "Backup transfered to the slave $slave_host successfully, logs available at $tmp_dir"
exit 0


