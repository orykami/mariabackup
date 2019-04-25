#!/bin/bash

##
# [Mariabackup agent]
# @author Orykami <88.jacquot.benoit@gmail.com>
##

MYSQL_USER=""
MYSQL_PASSWORD=""
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL="$(which mysql)"
MARIABACKUP="$(which mariabackup)"
MYSQLADMIN="$(which mysqladmin)"
FULL_SNAPSHOT_CYCLE=604800
ARGS=""

# Load script configuration from usual paths
if [[ -f config/mariabackup.conf ]]
then
  . config/mariabackup.conf
elif [[ -f ~/.mariabackup.conf ]]
then
  . ~/config/mariabackup.conf
elif [[ -f /etc/mariabackup.conf ]]
then
  . /etc/mariabackup.conf
else
  logger -p user.err -s "Configuration file (mariabackup.conf) not found."
  exit 1
fi

USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
START_TIME=`date +%s`
DATE="$(date +"%d-%m-%Y")"
TIME="$(date +"%H-%M-%S")"
RUN_DATE="$(date +%F_%H-%M)"

LOG_ARGS="-s -t mariabackup"


# Create recursive directory specified
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

# Write log to stdout/syslog
log() {
  logger -p $1 ${LOG_ARGS} $2
  return 0
}

##
# Main ()
##
log user.info "Start mariabackup.sh (Galera/MariaDB backup agent)"

# Create FULL_SNAPSHOT directory
mkdir_writable_directory ${FULL_SNAPSHOT_DIR}
if [[ $? -ne 0 ]]
then
  log user.err "'${FULL_SNAPSHOT_DIR}' does not exist or is not writable."
  exit 1
fi

# Create INCR_SNAPSHOT directory
mkdir_writable_directory ${INCR_SNAPSHOT_DIR}
if [[ $? -ne 0 ]]
then
  log user.err "'${INCR_SNAPSHOT_DIR}' does not exist or is not writable."
  exit 1
fi

# Ensure that mariabackup is able to connect to MariaDB server
if ! `echo 'exit' | ${MYSQL} -s ${USEROPTIONS}`
then
  log user.err "Can't connect to MariaDB instance (user/password missmatch ?)";
  exit 1
fi

# Retrieve latest full snapshot as reference for later
LATEST_FULL_SNAPSHOT=`find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1`
LATEST_FULL_SNAPSHOT_AGE=`stat -c %Y ${FULL_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}`
# Define next snapshot directories for FULL/INCR modes
NEXT_FULL_SNAPSHOT_DIR=${FULL_SNAPSHOT_DIR}/${RUN_DATE}
NEXT_INCR_SNAPSHOT_DIR=${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}/${RUN_DATE}

# Ensure that mariabackup is not running on the same repository (Lock mode)
if [[ -d ${NEXT_FULL_SNAPSHOT_DIR} ]]
then
  log user.info "Snapshot (FULL) ${RUN_DATE} already in progress/done, skip"
  exit 0
elif [[ -d ${NEXT_FULL_SNAPSHOT_DIR} ]]
then
  log user.info "Snapshot (INCR) ${RUN_DATE} already in progress/done, skip"
  exit 0
fi

# If latest full snapshot is expired, we should create a new full snapshost
if [ "$LATEST_FULL_SNAPSHOT" -a `expr ${LATEST_FULL_SNAPSHOT_AGE} + ${FULL_SNAPSHOT_CYCLE} + 5` -ge ${START_TIME} ]
then
  log user.info "Create new incremental snapshot"
  # Create incremental snapshot repository if needed
  mkdir_writable_directory ${NEXT_INCR_SNAPSHOT_DIR}
  if [[ $? -ne 0 ]]; then
    log user.info "'${NEXT_INCR_SNAPSHOT_DIR}' does not exist or is not writable."
    exit 1
  fi
  # Find latest incremental snapshot as reference for later
  LATEST_INCR_SNAPSHOT=`find ${NEXT_INCR_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1`
  if [[ -z ${LATEST_INCR_SNAPSHOT} ]]
  then
    INCR_BASE_DIR=${FULL_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}
  else
    INCR_BASE_DIR=${LATEST_INCR_SNAPSHOT}
  fi
  # Create next incremental snapshot directory
  mkdir -p ${NEXT_INCR_SNAPSHOT_DIR}
  # Start next incremental snapshot with mariabackup agent
  ${MARIABACKUP} \
    --backup ${USEROPTIONS} ${ARGS} \
    --extra-lsndir=${NEXT_INCR_SNAPSHOT_DIR} \
    --incremental-basedir=${INCR_BASE_DIR} \
    --stream=xbstream | gzip > ${NEXT_INCR_SNAPSHOT_DIR}/backup.stream.gz
else
  # Create next full snapshot directory
  log user.info "Create new full snapshot"
  # Create next full snapshot directory
  mkdir -p ${NEXT_FULL_SNAPSHOT_DIR}
  # Start next full snapshot with mariabackup agent
  ${MARIABACKUP} \
    --backup ${USEROPTIONS} ${ARGS} \
    --extra-lsndir=${NEXT_FULL_SNAPSHOT_DIR} \
    --stream=xbstream | gzip > ${NEXT_FULL_SNAPSHOT_DIR}/backup.stream.gz
fi

MINS=$((${FULL_SNAPSHOT_CYCLE} * (${SNAPSHOT_TTL} + 1 ) / 60))
log user.info "Cleaning backup older than ${MINS} minute(s)"
# Purge all expired snapshot cycles
for DEL in `find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d -mmin +${MINS} -printf "%P\n"`
do
  log user.info "Purged backup '${DEL}'"
  rm -rf ${FULL_SNAPSHOT_DIR}/${DEL}
  rm -rf ${INCR_SNAPSHOT_DIR}/${DEL}
done

DURATION=$((`date +%s` - ${START_TIME}))
log user.info "Backup completed in ${DURATION} seconds"
exit 0
