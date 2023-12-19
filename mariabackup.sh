#!/usr/bin/env bash

##
# [MariaDB backup script]
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
MYSQL_HOST="localhost"
# MariaDB SQL server port
MYSQL_PORT=3306
# Path to `mysql` command on your system
MYSQL="$(which mysql)"
# Webhook URL to notify for backup status
SLACK_WEBHOOK_URL=""
# Slack notification prefix
SLACK_PREFIX=""
# Path to `mariabackup` binary on your system
MARIABACKUP="$(which mariabackup)"
# Path to `myumper` binary on your system
MYDUMPER="$(which mydumper)"
# Path to `curl` binary on your system
CURL="$(which curl)"
# Default mariabackup directory
BACKUP_DIR=/tmp/mariabackup
# How many threads should we used by mariabackup command
MARIABACKUP_THREADS=4
# How many threads should we used by mydumper command
MYDUMPER_THREADS=4
# How many backups do we want to keep (in days)
BACKUP_TTL=3
# Additionnal mariabackup` arguments for runtime
MARIABACKUP_ARGS=""

# Retrieve configuration file from argument
while [[ $# -gt 1 ]]; do
    case $1 in
        # Configuration file (-c|--config)
        -c|--config)
            shift
            CONFIG_PATH="$1"
        ;;
    esac
    shift
done

# Load script configuration from specified path, exit otherwise
if [[ -f ${CONFIG_PATH} ]]
then
  . ${CONFIG_PATH}
else
  logger -p user.err -s "Configuration file ${CONFIG_PATH} not found."
  exit 1
fi

# Ensure mariabackup binary is defined in $PATH
if [[ -z ${MARIABACKUP} ]]
then
  logger -p user.err -s "Cannot locate mariabackup binary in ${PATH}"
  exit 1
fi

# Ensure mydumper binary is defined in $PATH
if [[ -z ${MYDUMPER} ]]
then
  logger -p user.err -s "Cannot locate mydumper binary in ${PATH}"
  exit 1
fi

# Ensure curl binary is defined in $PATH if SLACK_WEBHOOK_URL is specified
if [[ -z ${CURL} ]] && [[ ! -z ${SLACK_WEBHOOK_URL} ]]
then
  logger -p user.err -s "Cannot locate curl binary in ${PATH} (required for Slack notification)"
  exit 1
fi

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
  logger -p $1 -s -t mariabackup $2
  return 0
}

##
# Notify slack via webhook with arguments
# @param $1 Notification message
##
notify_slack() {
  # Notify #devops on Slack network if webhook is specified
  if [[ -n ${SLACK_WEBHOOK_URL} ]]; then
    printf -v JSON '{"text":"[%s%s][%s] %s"}' "${SLACK_PREFIX}" ${HOST} ${RUN_DATE} "$1"
    ${CURL} -X POST -H 'Content-type: application/json' --insecure --data  "$JSON" ${SLACK_WEBHOOK_URL} > /dev/null 2>&1
  fi
  return 0
}

##
# Create dumps backup with mydumper
##
do_dumps_backup() {
    ${MYDUMPER} \
        --host=${MYSQL_HOST} \
        --user=${MYSQL_USER} \
        --password=${MYSQL_PASSWORD} \
        --port=${MYSQL_PORT} \
        --outputdir=${DUMPS_BACKUP_DIR} \
        --compress \
        --compress-protocol \
        --rows=50000 \
        --threads=${MYDUMPER_THREADS} \
        --triggers \
        --events \
        --routines \
        --build-empty-files \
        --verbose 3 \
        --regex '^(?!(mysql|test|performance_schema|information_schema|sys))' \
        --logfile ${CURRENT_BACKUP_DIR}/${TIME}/mydumper.log

    if [[ $? -ne 0 ]]
    then
      ERROR_MESSAGE="Logical backup '${DUMPS_BACKUP_DIR}' failed"
      log user.err "${ERROR_MESSAGE}"
      notify_slack "${ERROR_MESSAGE}"
    fi

    return 0
}

##
# Create files backup with mariabackup
# @param string $1 Latest full backup for incremental backup setup
##
do_files_backup() {
  if [[ $# -eq 1 && -d $1 ]]
  then
    ${MARIABACKUP} \
      --backup ${USEROPTIONS} ${MARIABACKUP_ARGS} \
      --parallel=${MARIABACKUP_THREADS} \
      --extra-lsndir=${FILES_BACKUP_DIR} \
      --incremental-basedir=$1 \
      --stream=xbstream 2> ${CURRENT_BACKUP_DIR}/${TIME}/mariabackup.log \
      | gzip > ${FILES_BACKUP_DIR}/snapshot.stream.gz
  else
    ${MARIABACKUP} \
      --backup ${USEROPTIONS} ${MARIABACKUP_ARGS} \
      --parallel=${MARIABACKUP_THREADS} \
      --extra-lsndir=${FILES_BACKUP_DIR} \
      --stream=xbstream 2> ${CURRENT_BACKUP_DIR}/${TIME}/mariabackup.log \
      | gzip > ${FILES_BACKUP_DIR}/snapshot.stream.gz
  fi

  if [[ $? -ne 0 ]]
  then
    ERROR_MESSAGE="Physical backup '${FILES_BACKUP_DIR}' failed"
    log user.err "${ERROR_MESSAGE}"
    notify_slack "${ERROR_MESSAGE}"
  fi

  return 0
}

##
# Main script ()
##
START_TIME=`date +%s`
RUN_DATE="$(date +%F_%H-%M)"
DATE="$(date +"%Y-%m-%d")"
TIME="$(date +"%H-%M-00")"
USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
log user.info "Start mariabackup (MariaDB backup agent)"
CURRENT_BACKUP_DIR="${BACKUP_DIR}/${DATE}"
# Create CURRENT_BACKUP_DIR directory and subfolders
mkdir_writable_directory ${CURRENT_BACKUP_DIR}
if [[ $? -ne 0 ]]
then
  ERROR_MESSAGE="'${CURRENT_BACKUP_DIR}' does not exist or is not writable."
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1
fi

# Ensure that mariabackup is able to connect to MariaDB server
if ! `echo 'exit' | ${MYSQL} -s ${USEROPTIONS}`
then
  ERROR_MESSAGE="Can't connect to MariaDB instance (Host is up ?)"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 1
fi

PREVIOUS_BACKUP_DIR=""
# First, try to retrieve an existing previous backup for mariabackup incremental backup
LAST_BACKUP_TIME=`find "${CURRENT_BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1`
if [[ -d "${LAST_BACKUP_TIME}/files" ]]
then
  PREVIOUS_BACKUP_DIR="${LAST_BACKUP_TIME}/files"
fi

# Create folders for backup storage
FILES_BACKUP_DIR="${CURRENT_BACKUP_DIR}/${TIME}/files"
DUMPS_BACKUP_DIR="${CURRENT_BACKUP_DIR}/${TIME}/dumps"

if [[ -d ${FILES_BACKUP_DIR} ]] || [[ -d ${FILES_BACKUP_DIR} ]]
then
  ERROR_MESSAGE="Backup ${CURRENT_BACKUP_DIR}/${TIME} already exists"
  log user.err "${ERROR_MESSAGE}"
  notify_slack "${ERROR_MESSAGE}"
  exit 0
fi

mkdir_writable_directory ${FILES_BACKUP_DIR}
mkdir_writable_directory ${DUMPS_BACKUP_DIR}

# Do physical backup via mariabackup and logical backup via mydumper
do_files_backup ${PREVIOUS_BACKUP_DIR}
do_dumps_backup

# Retrieve how many snapshot cycles are already in storage, and purge old snapshots if required
BACKUP_COUNT=`find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d | wc -l`
log user.info "Current backups : ${BACKUP_COUNT}/${BACKUP_TTL}"
if [[ ${BACKUP_COUNT} -gt ${BACKUP_TTL} ]]; then
  TO_PURGE_BACKUP_COUNT=$(expr ${BACKUP_COUNT} - ${BACKUP_TTL})
  log user.info "Pruning ${TO_PURGE_BACKUP_COUNT} expired backup(s)"
  for OLD_BACKUP in `find ${BACKUP_DIR} -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -n | head -${TO_PURGE_BACKUP_COUNT}`
  do
    rm -rf ${BACKUP_DIR}/${OLD_BACKUP}
    log user.info "'${OLD_BACKUP}' backup pruned"
  done
fi

# Create log entry for backup trace
DURATION=$((`date +%s` - ${START_TIME}))
log user.info "Backup completed in ${DURATION} seconds"

# Notify #devops on Slack network if webhook is specified
if [[ -n ${SLACK_WEBHOOK_URL} ]]; then
  SUCCESS_MESSAGE="MariaDB backup completed in ${DURATION} second(s)"
  notify_slack "${SUCCESS_MESSAGE}"
fi

exit 0
