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
  echo -e "Configuration file (mariabackup.conf) not found."
  exit 1
fi

USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
START_TIME=`date +%s`
DATE="$(date +"%d-%m-%Y")"
TIME="$(date +"%H-%M-%S")"


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

##
# Main ()
##
echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [info] Start mariabackup.sh (Galera/MariaDB backup agent)"

# Create FULL_SNAPSHOT directory
mkdir_writable_directory ${FULL_SNAPSHOT_DIR}
if [[ $? -ne 0 ]]
then
  echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [error] '${FULL_SNAPSHOT_DIR}' does not exist or is not writable."
  exit 1
fi

# Create INCR_SNAPSHOT directory
mkdir_writable_directory ${INCR_SNAPSHOT_DIR}
if [[ $? -ne 0 ]]
then
  echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [error] '${INCR_SNAPSHOT_DIR}' does not exist or is not writable."
  exit 1
fi

# Ensure that mariabackup is able to connect to MariaDB server
if ! `echo 'exit' | ${MYSQL} -s ${USEROPTIONS}`
then
  echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [error] Can't connect to MariaDB instance (user/password missmatch ?)";
  exit 1
fi

# Find latest full backup snapshot as reference for later
LATEST_FULL_SNAPSHOT=`find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1`
LATEST_FULL_SNAPSHOT_AGE=`stat -c %Y ${FULL_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}`

# If latest full snapshot is expired, we should create a new full snapshost
if [ "$LATEST_FULL_SNAPSHOT" -a `expr ${LATEST_FULL_SNAPSHOT_AGE} + ${FULL_SNAPSHOT_CYCLE} + 5` -ge ${START_TIME} ]
then
  echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [info] Create new incremental snapshot"
  # Create incremental snapshot repository if needed
  mkdir_writable_directory ${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}
  if [[ $? -ne 0 ]]; then
    echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [error] '${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}' does not exist or is not writable."
    exit 1
  fi

  # Find latest incremental snapshot as reference for later
  LATEST_INCR_SNAPSHOT=`find ${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT} -mindepth 1  -maxdepth 1 -type d | sort -nr | head -1`
  if [[ -z ${LATEST_INCR_SNAPSHOT} ]]
  then
    INCR_BASE_DIR=${FULL_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}
  else
    INCR_BASE_DIR=${LATEST_INCR_SNAPSHOT}
  fi

  # Create next incremental snapshot directory
  NEXT_SNAPSHOT_DIR=${INCR_SNAPSHOT_DIR}/${LATEST_FULL_SNAPSHOT}/`date +%F_%H-%M-%S`
  mkdir -p ${NEXT_SNAPSHOT_DIR}

  # Start next incremental snapshot with mariabackup agent
  ${MARIABACKUP} \
    --backup ${USEROPTIONS} ${ARGS} \
    --extra-lsndir=${NEXT_SNAPSHOT_DIR} \
    --incremental-basedir=${INCR_BASE_DIR} \
    --stream=xbstream | gzip > ${NEXT_SNAPSHOT_DIR}/backup.stream.gz
else
  # Create next full snapshot directory
  echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [info] Create new full snapshot"
  NEXT_SNAPSHOT_DIR=${FULL_SNAPSHOT_DIR}/`date +%F_%H-%M-%S`
  mkdir -p ${NEXT_SNAPSHOT_DIR}

  # Start next full snapshot with mariabackup agent
  ${MARIABACKUP} \
    --backup ${USEROPTIONS} ${ARGS} \
    --extra-lsndir=${NEXT_SNAPSHOT_DIR} \
    --stream=xbstream | gzip > ${NEXT_SNAPSHOT_DIR}/backup.stream.gz
fi

MINS=$((${FULL_SNAPSHOT_CYCLE} * (${SNAPSHOT_TTL} + 1 ) / 60))
echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [info] Cleaning backup older than ${MINS} minute(s)"
# Purge all expired snapshot cycles
for DEL in `find ${FULL_SNAPSHOT_DIR} -mindepth 1 -maxdepth 1 -type d -mmin +${MINS} -printf "%P\n"`
do
  echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [info] Purged backup '${DEL}'"
  rm -rf ${FULL_SNAPSHOT_DIR}/${DEL}
  rm -rf ${INCR_SNAPSHOT_DIR}/${DEL}
done

DURATION=$((`date +%s` - ${START_TIME}))
echo -e "[`date +"%d/%m/%Y %H:%M:%S"`] ${MYSQL_HOST} [info] Backup completed in ${DURATION} seconds"
exit 0
