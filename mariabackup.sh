#!/bin/bash

##
# [Mariabackup agent]
# @author orykami <88.jacquot.benoit@gmail.com>
##

# Hostname
HOST=${HOSTNAME}
# Mariabackup agent configuration path
CONFIG_PATH="/etc/mariabackup.conf"
# MariaDB backup agent on your SQL server
MYSQL_USER="mariabackup"
# MariaDB backup agent password on your SQL server
MYSQL_PASSWORD=""
# MariaDB SQL server host
MYSQL_HOST=localhost
# MariaDB SQL server port
MYSQL_PORT=3306
# Path to `mysql` command on your system
MYSQL="$(which mysql)"
# Webhook URL to notify for backup status
SLACK_WEBHOOK_URL=""
# Path to `mariabackup` command on your system
MARIABACKUP="$(which mariabackup)"
# Path to `mysqladmin` command on your system
MYSQLADMIN="$(which mysqladmin)"
# Path to `curl` command on your system
CURL="$(which curl)"
# Snapshot lifecyle (in seconds)
# - Create a full snapshot every ${FULL_SNAPSHOT_CYCLE} seconds)
# - Create a incr snapshot between every ${FULL_SNAPSHOT_CYCLE} seconds
FULL_SNAPSHOT_CYCLE=86400
# Default snapshot directory
SNAPSHOT_DIR=/tmp/mariabackup
# Default FULL snapshot directory
FULL_SNAPSHOT_DIR=${SNAPSHOT_DIR}/full
# Default INCR snapshot directory
INCR_SNAPSHOT_DIR=${SNAPSHOT_DIR}/incr
# How many snapshot do we want to keep
SNAPSHOT_PRESERVE_COUNT=5
# Additionnal mariabackup` arguments for runtime
MARIABACKUP_ARGS=""

##
# Retrieve configuration file from argument
##
while [[ $# > 1 ]]; do
    case $1 in
        # Configuration file (-c|--config)
        -c|--config)
            shift
            CONFIG_PATH="$1"
        ;;
    esac
    shift
done

##
# Load script configuration from specified path, exit otherwise
##
if [[ -f ${CONFIG_PATH} ]]
then
  . ${CONFIG_PATH}
else
  logger -p user.err -s "Configuration file ${CONFIG_PATH} not found."
  exit 1
fi

##
# Default runtime vars
##
USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
START_TIME=`date +%s`
DATE="$(date +"%d-%m-%Y")"
TIME="$(date +"%H-%M-%S")"
RUN_DATE="$(date +%F_%H-%M)"
LOG_ARGS="-s -t mariabackup"

##
# Create recursive directory specified
# @param $1 Path to directory to create
##
mkdir_writable_directory() {
  if [[ $# -ne 1 ]] || [[ -z $1 ]]
  then
    return 1
  fi
  if [[ ! -d $1 ]]
  then
    mkdir -p $1 &> /dev/null || return 1
  fi

  chmod 600 $1 &> /dev/null || return 1
  return 0
}

##
# Write log to stdout/syslog
# @param $1 log.level Log level
# @param $2 Log message
##
log() {
  logger -p $1 ${LOG_ARGS} $2
  return 0
}

##
# Notify slack via webhook with arguments
# @param $1 Notification message
#
##
notify_slack() {
  # Notify #devops on Slack network if webhook is specified
  if [[ -n ${SLACK_WEBHOOK_URL} ]]; then
    printf -v JSON '{"text":"[%s][%s] %s"}' ${HOST} ${RUN_DATE} $1
    ${CURL} -X POST -H 'Content-type: application/json' --data "$JSON" ${SLACK_WEBHOOK_URL} > /dev/null 2>&1
  fi
  return 0
}

##
# Main script ()
##
log user.info "Start mariabackup.sh (Galera/MariaDB backup agent)"

# Create FULL_SNAPSHOT directory
mkdir_writable_directory ${FULL_SNAPSHOT_DIR}
if [[ $? -ne 0 ]]
then
  ERROR_MESSAGE="'${FULL_SNAPSHOT_DIR}' does not exist or is not writable."
  log user.err ${ERROR_MESSAGE}
  notify_slack ${ERROR_MESSAGE}
  exit 1
fi

# Create INCR_SNAPSHOT directory
mkdir_writable_directory ${INCR_SNAPSHOT_DIR}
if [[ $? -ne 0 ]]
then
  ERROR_MESSAGE="'${INCR_SNAPSHOT_DIR}' does not exist or is not writable."
  log user.err ${ERROR_MESSAGE}
  notify_slack ${ERROR_MESSAGE}
  exit 1
fi

# Ensure that mariabackup is able to connect to MariaDB server
if ! `echo 'exit' | ${MYSQL} -s ${USEROPTIONS}`
then
  ERROR_MESSAGE="Can't connect to MariaDB instance (user/password missmatch ?)"
  log user.err ${ERROR_MESSAGE}
  notify_slack ${ERROR_MESSAGE}
  exit 1
fi

# Retrieve latest full snapshot as reference for later
LATEST_FULL_SNAPSHOT=`find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1`
LATEST_FULL_SNAPSHOT_AGE=`stat -c %Y ${FULL_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}`
# Define next snapshot directories for FULL/INCR modes
NEXT_FULL_SNAPSHOT=${FULL_SNAPSHOT_DIR}/${RUN_DATE}
NEXT_INCR_SNAPSHOT=${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}/${RUN_DATE}

# Ensure that mariabackup is not running on the same repository (Lock mode)
if [[ -d ${NEXT_FULL_SNAPSHOT} ]]
then
  log user.info "Snapshot (FULL) ${RUN_DATE} already in progress/done, skip"
  exit 0
elif [[ -d ${NEXT_INCR_SNAPSHOT} ]]
then
  log user.info "Snapshot (INCR) ${RUN_DATE} already in progress/done, skip"
  exit 0
fi

# If latest full snapshot is expired, we should create a new full snapshost
if [ "$LATEST_FULL_SNAPSHOT" -a `expr ${LATEST_FULL_SNAPSHOT_AGE} + ${FULL_SNAPSHOT_CYCLE} + 5` -ge ${START_TIME} ]
then
  log user.info "Create new incremental snapshot"
  # Create incremental snapshot repository if needed
  mkdir_writable_directory ${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}
  if [[ $? -ne 0 ]]; then
    ERROR_MESSAGE="'${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}' does not exist or is not writable."
    log user.err ${ERROR_MESSAGE}
    notify_slack ${ERROR_MESSAGE}
    exit 1
  fi
  # Find latest incremental snapshot as reference for later
  LATEST_INCR_SNAPSHOT=`find ${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT} -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1`
  if [[ -z ${LATEST_INCR_SNAPSHOT} ]]
  then
    INCR_BASE_DIR=${FULL_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}
  else
    INCR_BASE_DIR=${LATEST_INCR_SNAPSHOT}
  fi
  # Create next incremental snapshot directory
  mkdir -p ${NEXT_INCR_SNAPSHOT}
  # Start next incremental snapshot with mariabackup agent
  ${MARIABACKUP} \
    --backup ${USEROPTIONS} ${MARIABACKUP_ARGS} \
    --extra-lsndir=${NEXT_INCR_SNAPSHOT} \
    --incremental-basedir=${INCR_BASE_DIR} \
    --stream=xbstream | gzip > ${NEXT_INCR_SNAPSHOT}/snapshot.stream.gz
else
  # Create next full snapshot directory
  log user.info "Create new full snapshot"
  # Create next full snapshot directory
  mkdir -p ${NEXT_FULL_SNAPSHOT}
  # Start next full snapshot with mariabackup agent
  ${MARIABACKUP} \
    --backup ${USEROPTIONS} ${MARIABACKUP_ARGS} \
    --extra-lsndir=${NEXT_FULL_SNAPSHOT} \
    --stream=xbstream | gzip > ${NEXT_FULL_SNAPSHOT}/snapshot.stream.gz
fi

# Retrieve how many snapshot cycles are already in storage, and purge old snapshots if required
SNAPSHOT_COUNT=$(find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d | wc -l)
log user.info "Current snapshot count : ${SNAPSHOT_COUNT}/${SNAPSHOT_PRESERVE_COUNT}"
if [[ ${SNAPSHOT_COUNT} -gt ${SNAPSHOT_PRESERVE_COUNT} ]]; then
  TO_PURGE_SNAPSHOT_COUNT=$(expr ${SNAPSHOT_COUNT} - ${SNAPSHOT_PRESERVE_COUNT})
  if [[ ${TO_PURGE_SNAPSHOT_COUNT} -gt 0 ]]; then
    log user.info "Start pruning ${TO_PURGE_SNAPSHOT_COUNT} snapshot(s)"
    for OLD_SNAPSHOT in `find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -n | head -${TO_PURGE_SNAPSHOT_COUNT}`
    do
      log user.info "Purged backup '${OLD_SNAPSHOT}'"
      rm -rf ${FULL_SNAPSHOT_DIR}/${OLD_SNAPSHOT}
      rm -rf ${INCR_SNAPSHOT_DIR}/${OLD_SNAPSHOT}
    done
  fi
fi

# Create log entry for backup trace
DURATION=$((`date +%s` - ${START_TIME}))
log user.info "Backup completed in ${DURATION} seconds"

# Notify #devops on Slack network if webhook is specified
if [[ -n ${SLACK_WEBHOOK_URL} ]]; then
  SUCCESS_MESSAGE="MariaDB snapshot completed in ${DURATION} second(s)"
  notify_slack ${SUCCESS_MESSAGE}
fi

exit 0
