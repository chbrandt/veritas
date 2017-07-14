FILEROOTNAME#!/bin/bash
set -ueE

THISDIR=$(cd `dirname ${BASH_SOURCE}`; pwd)
#TODO: probably define LOGDIR in base of LOGFILE (if there is)
LOGDIR=${LOGDIR:-${THISDIR}/log}
[ -d $LOGDIR ] || mkdir -p $LOGDIR

source "${THISDIR}/../env.sh"

# We'll need the VERITAS' public data directory declared..
[ -n "$REPO_VERITAS" ] || { 1>&2 echo "Environment not loaded"; exit 1; }

# TMPDIR will have all the temporary files and partial products.
# At the end, products, log files will are copied from it.
TMPDIR="$(mktemp -d)"
remove_temp() {
  if [ -d "$TMPDIR" ]; then
    rm -rf $TMPDIR
  fi
}

# LOCKFILE will avoid concurrence between instances of 'git_commit' function
LOCKFILE='/tmp/veritas.lock'
create_lock() {
  touch $LOCKFILE
}
remove_lock() {
  if [ -f $LOCKFILE ]; then
    rm $LOCKFILE
  fi
}

clean_exit() {
  remove_lock
  remove_temp
}
trap clean_exit EXIT

error_exit() {
  cp ${TMPDIR}/* ${LOGDIR}/.
  clean_exit
}
trap error_exit ERR



is_file_ok () {
  FILE="$1"
  [ -f "$FILE" ]        || return 1
  return 0
}

csv2fits() {
  # Run the script to convert csv (veritas format) to fits
  # Arguments:
  FILEIN="$1"
  FILEOUT="$2"
  FILELOG="${3:-/dev/null}"
  FLOGERR="${4:-/dev/null}"

  : ${REPO_VERITAS_PROC:?'VERITAS repo not defined'}

  # We have Anaconda managing our python env in the background
  # The python virtual-env is properly called 'veritas'
  # source activate veritas
  _script="${REPO_VERITAS_PROC}/csv2fits.py"
  /opt/anaconda/bin/python $_script $FILEIN $FILEOUT > $FILELOG 2> $FLOGERR
  return
}



add_untracked() {
  for uf in `git status --porcelain | xargs -I{} echo {} | cut -d' ' -f2`
  do
    git add $uf
  done
  return
}

fetch_gavo() {
  : ${GAVO_ROOT:?GAVO_ROOT not defined}
  sleep 5
  (
    cd "${GAVO_ROOT}/inputs/veritas"  &&\
    git fetch && git pull             &&\
    gavo imp q.rd
  )
  return
}

make_changes() {
  local EVENT="$1"
  local FILES="${@:2}"

  # Do the commit/push
  (
    cd $REPO_VERITAS

    if [[ "$EVENT" =~ "MOVED" || "$EVENT" =~ "MODIFY" ]]; then
      for f in ${FILES}; do
        git add $FILES
      done
    fi

    if [[ "$EVENT" =~ "DELETE" ]]; then
      _trash="${REPO_VERITAS_DATA_SRC}/trash"
      for f in ${FILES}; do
        git mv $FILES   ${_trash}/.
      done
    fi

    git commit -am "inotify changes $EVENT"           && \
    git push
  )
  # and update GAVO
  fetch_gavo
  return
}

git_commit() {
  # Arguments:
  # local EVENT="$1"
  # local FILES="${@:2}"

  : ${REPO_VERITAS:?'VERITAS repo not defined'}

  while [ -f $LOCKFILE ]
  do
    sleep 1
  done
  create_lock

  make_changes $@

  remove_lock
  return
}

delete() {
  # Arguments:
  local CSV_FILE="$1"
  local DIR_IN="$2"
  local EVENT="$3"

  : ${REPO_VERITAS_DATA_PUB?'VERITAS repo not defined'}

  # Remove filename from $REPO_VERITAS_DATA_PUB
  # and commit the change
  FITS_FILE="${CSV_FILE%.*}.fits"
  local FILEPUB="${REPO_VERITAS_DATA_PUB}/$FITS_FILE"
  local FILESRC="${REPO_VERITAS_DATA_SRC}/$CSV_FILE"

  git_commit $EVENT $FILEPUB $FILESRC
  return
}

modify() {
  # Arguments:
  local FILENAME="$1"
  local DIR_IN="$2"
  local EVENT="$3"

  : ${REPO_VERITAS_DATA_PUB?'VERITAS repo not defined'}

  local ARCHIVE_LOG="${DIR_IN}/log"
  [ -d "$ARCHIVE_LOG" ] || mkdir $ARCHIVE_LOG

  # Run veritas' csv2fits python script
  # If csv2fits succeeds, copy result to $REPO_VERITAS_DATA_PUB
  # and commit the change

  local FILEIN="${DIR_IN}/${FILENAME}"
  is_file_ok $FILEIN || return 1

  local FILEROOTNAME="${FILENAME%.*}"
  local FILEOUT="${TMPDIR}/${FILEROOTNAME}.fits"
  local FILELOG="${TMPDIR}/${FILEROOTNAME}_${EVENT#*_}.log"
  local FLOGERR="${FILELOG}.error"

  #XXX: until Astropy-issue#6367 gets fixed we will workaround here..
  local FILEIN_TMP="${TMPDIR}/${FILENAME}"
  local FILETMP="${TMPDIR}/${FILENAME}.tmp"
  grep "^#" $FILEIN > $FILETMP
  grep -v "^#" $FILEIN | tr -s "\t" " " >> $FILETMP
  cp $FILETMP $FILEIN_TMP && rm $FILETMP
  unset FILETMP

  # csv2fits $FILEIN $FILEOUT $FILELOG $FLOGERR
  csv2fits $FILEIN_TMP $FILEOUT $FILELOG $FLOGERR

  if [ "$?" == "0" ]; then
    local FOUT=$(basename $FILEOUT)
    local FILEPUB="${REPO_VERITAS_DATA_PUB}/$FOUT"
    cp $FILEOUT     $FILEPUB
    unset FOUT

    # cp $FILEIN    $REPO_VERITAS_DATA_SRC
    local FOUT=$(basename $FILEIN_TMP)
    local FILESRC="${REPO_VERITAS_DATA_SRC}/$FOUT"
    cp $FILEIN_TMP  $FILESRC
    unset FOUT

    git_commit $EVENT $FILEPUB $FILESRC
    unset FILEPUB FILESRC
  else
    1>&2 echo "CSV2FITS failed. Output at '$LOGDIR'"
  fi
  # Always copy the log/err output to archive's feedback
  cp $FILELOG $FLOGERR   $ARCHIVE_LOG
  return
}
