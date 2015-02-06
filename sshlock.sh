#!/bin/bash 
remotecommand=
remotefile=
desiredvalue=
maxwait=-1
maxremotehosterrors=-1
debug=
is_readlock=
is_grablock=
is_releaselock=
is_showwaitprogress=
function usage() {
cat >&2 <<EOJ
Usage: ${0##*/} --remotecommand 'ssh remotehost' 
  --file /root/lock.file 
  --key \$(hostname) .  some unique value that identifies you as the holding process.  e.g. a server hostname.  when you release the lock you need 
      to use the same key as you did with the lock.  The key should not be something another process contending for the lock would use.
  acquire | release | read.  Grab release or read the lock (one or more of these)
  [--maxwait 60 ].  to wait a maxiumum of 60 seconds for the lock, else getlock will return an error
  [ --maxremotehosterrors number ].  exit after seeing this many errors from the remotecommand.  e.g. if that remote server is not up or not accepting your credentials.
  [ --debug | -v | -vv ].  Output debug info to stderr
  [ --progress ].  Output wait progress. 
  
  Tips:
   - to be usable you will want automated logins enabled.  e.g. ssh key authentication.
  
  Examples:
  # reading when no prior lock exists
[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo read
Readlock: ssh host987:/tmp/foo:No file: /tmp/foo

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo acquire --key 'secret'
# lock is acquired here

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo acquire --key 'badsecret' --progress --maxwait 20
Waiting for a server lock on ssh host987:/tmp/foo currently in use by 'secret'
Get lock timed out
[root@hosta xen]# echo $?
1
# lock was not reacquired since the secret did not match


[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo acquire --key 'secret' --progress
# lock is reacquired ok (since we already hold it/that secret)

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo read
Readlock: ssh host987:/tmp/foo:secret

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo release  --key 'badsecret'
Key did not match, nothing to release.
# releasing the lock with the wrong secret returns immediately

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo release  --key 'secret'
# releases ok

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo release  --key 'secret'
# didn't have the lock, release it again no problems

If you are scripting this, then you will likely need an ssh-agent and keys.  Running the following prior to sshlock.sh should work well:
  SSHAGENT=/usr/bin/ssh-agent
  SSHAGENTARGS="-s"
  if [ -z "$SSH_AUTH_SOCK" -a -x "$SSHAGENT" ]; then
    eval $($SSHAGENT $SSHAGENTARGS)
    echo "Creating an aget $SSH_AGENT_PID"
    trap "kill $SSH_AGENT_PID && echo killing agent $SSH_AGENT_PID" 0
  fi
  # add a passwordless private key file
  ssh-add -l | grep -qai 'somekeyname' || ssh-add somekey.private.key
EOJ
}

while true; do
  if [ -z "$1" ]; then break; fi
  case "$1" in
  --file)
    shift
    if [ -z "$1" ]; then
      echo "expecting file " >&2
      exit 1
    fi
    remotefile=$1
    ;;
  --remotecommand)
    shift
    if [ -z "$1" ]; then
      echo "expecting remotecommand. e.g. ssh remotehost  e.g. batchssh -p 2022 peter@remotehost" >&2
      exit 1
    fi
    remotecommand=$1
    ;;
  --key)
    shift
    if [ -z "$1" ]; then
      echo "expecting text " >&2
      exit 1
    fi
    desiredvalue=$1
    ;;
  --maxwait)
    shift
    if [ -z "$1" ]; then
      echo "expecting wait time (in s) " >&2
      exit 1
    fi
    maxwait=$1
    ;;
  --maxremotehosterrors)
    shift
    if [ -z "$1" ]; then
      echo "expecting maximum number of errors before quitting" >&2
      exit 1
    fi
    maxremotehosterrors=$1
    ;;
  --debug|-v|-vv|-vvv)
    debug=Y
    ;;
  --progress)
    is_showwaitprogress=Y
    ;;
  acquire)
    is_grablock="Y"
    ;;
  release)
    is_releaselock="Y"
    ;;
  read)
    is_readlock="Y"
    ;;
  *)
    echo "Unrecognized argument $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

if [ -z "$is_grablock" ] && [ -z "$is_releaselock" ] && [ -z "$is_readlock" ]; then
  usage && exit 1 
fi
[ -z "$remotecommand" ] && echo "Missing --remotecommand" >&2 && usage && exit 1
[ -z "$remotefile" ] && echo "Missing --file" >&2 && usage && exit 1

starttime=$(date +%s)
remotehosterrors=0

function grablock() {
  [ -z "$desiredvalue" ] && echo "Missing --desiredvalue" >&2 && usage && exit 1
  local i=0
  while true; do
  [ $maxwait -gt -1 ] && [ $(($(date +%s) - $starttime)) -gt $maxwait ] && echo "Get lock timed out" >&2 && return 1 
  # sleep a bit to avoid everyone hammering on the remote host.  makes it random who gets the next lock (vs. just server with
  # lowest ping time)
  # After more failed attempts we wait longer between attempts
  sleep $((($RANDOM % 20) * $([ $i -gt 10 ] && echo 10 || echo $i)))
  i=$(($i+1))
  tmp=$(mktemp /tmp/currentval.XXX)
  $remotecommand "false && echo -n 'gl $desiredvalue '>&2; false && cat '$remotefile' >&2; if [ ! -e '$remotefile' ] ; then touch '$remotefile' || exit 1; fi; [ ! -f '$remotefile' ] && exit 1; [ ! -s '$remotefile' ] && echo 'free$RANDOM' > '$remotefile'; cat '$remotefile'" > $tmp
  ret=$?
  if [ $ret -ne 0 ]; then
    if [ $maxremotehosterrors -gt -1 -o ! -z "$debug" ]; then
        $remotecommand "true" 
        if [ $? -ne 0 ]; then 
          remotehosterrors=$(($remotehosterrors+1))
          [ ! -z "$debug" ] && echo "Got an error from $remotecommand.  Errors to date $remotehosterrors"
        fi 
        if [ $maxremotehosterrors -ge 0 -a $remotehosterrors -ge $maxremotehosterrors ]; then
          echo "Exceeding the maximum number of remote host errors getting the lock.  Is the remote host down or not accepting your credentials?" >&2
          return 1 
        fi
    fi
    continue
  fi
  currentval=$(cat $tmp)
  rm -f $tmp
  false && echo "glc $currentval vs. $desiredvalue" >&2
  if [ "$currentval" == "$desiredvalue" ]; then
    [ ! -z "$debug" ] && echo "Acknowledging existing lock $remotecommand:$remotefile = '$desiredvalue'" >&2
    return 0
  fi
  if echo $currentval | grep -qai '^free[0-9]*$'; then
    # ours for the taking if we win the race.
    true
  else 
    [ $(( $i % 5)) -eq 0 ] && [ ! -z "$debug" -o ! -z '$is_showwaitprogress' ] && echo "Waiting for a server lock on $remotecommand:$remotefile currently in use by '$currentval'" >&2
    continue
  fi
  $remotecommand "if [ ! -e '$remotefile' ]; then exit 1; fi; [ \"\$(cat '$remotefile')\" == '$currentval' ] && echo '$desiredvalue' > '$remotefile' && exit 0; exit 1"
  ret=$?
  if [ $ret -eq 0 ]; then
    [ ! -z "$debug" ] && echo "Acquired lock $remotecommand:$remotefile = '$desiredvalue'" >&2
    return 0
  fi
  done
}

function readlock() {
tmp=$(mktemp /tmp/readlock.XXX)
$remotecommand "[ ! -e '$remotefile' ] && echo 'No file: $remotefile' && exit 0; [ ! -s '$remotefile' ] && echo 'Empty remote file' && exit 0; cat '$remotefile'" > $tmp
ret=$?
if [ $ret -ne 0 ]; then
  echo "Readlock failed." >&2
  rm -f $tmp 
  exit 1
fi
echo "Readlock: $remotecommand:$remotefile:$(cat $tmp)"
rm -f $tmp
}
# returns 0 if we released the lock, or if the secret didn't match and we don't own the lock anyway
# return non-zero if we fail to communicate with the remote server
function releaselock() {
  local startime=$(date +%s)
  local remotehosterrors=0
  i=0
  [ -z "$desiredvalue" ] && echo "Missing --desiredvalue" >&2 && usage && exit 1
  while true; do
    [ $maxwait -gt -1 ] && [ $(($(date +%s) - $starttime)) -gt $maxwait ] && echo "Get lock timed out" >&2 && return 1 
    # sleep a bit to avoid everyone hammering on the remote host.  makes it random who gets the next lock (vs. just server with
    # lowest ping time)
    # After more failed attempts we wait longer between attempts
    sleep $((($RANDOM % 20) * $([ $i -gt 10 ] && echo 10 || echo $i)))
    i=$(($i+1))
    tmp=$(mktemp /tmp/releaselock.XXX)
    $remotecommand "false && echo -n 'rl $desiredvalue '>&2; false && cat '$remotefile' >&2; [ ! -e '$remotefile' ] && echo '==ERRNOFILE' && exit 0; grep -qai '^free[0-9]*$' '$remotefile' && echo '==ERRFREEALREADY' && exit 0; [ \"\$(cat '$remotefile')\" == '$desiredvalue' ] && echo 'free$RANDOM' > '$remotefile' && exit 0; echo '==ERRNOMATCH'; exit 0" > $tmp
    ret=$?
    grep -qai '^==ERRNOMATCH' $tmp && rm -f $tmp && echo "Key did not match, nothing to release." >&2 && return 0
    if grep -qai '^==ERRNOFILE' $tmp; then
      rm -f $tmp;
      [ ! -z "$debug" ] && echo "Skipping release lock, no $remotecommand:$remotefile present" >&2
      return 0 
    fi
    if grep -qai '^==ERRFREEALREADY' $tmp; then
      rm -f $tmp;
      [ ! -z "$debug" ] && echo "Skipping release lock, $remotecommand:$remotefile was free already" >&2
      return 0 
    fi
    rm -f $tmp;
    if [ $ret -eq 0 ]; then
      return 0
    fi
    if [ $ret -ne 0 ]; then
      if [ $maxremotehosterrors -gt -1 -o ! -z "$debug" ]; then
          $remotecommand "true" 
          if [ $? -ne 0 ]; then 
            remotehosterrors=$(($remotehosterrors+1))
            [ ! -z "$debug" ] && echo "Got an error from $remotecommand.  Errors to date $remotehosterrors"
          fi 
          if [ $maxremotehosterrors -ge 0 -a $remotehosterrors -ge $maxremotehosterrors ]; then
            echo "Exceeding the maximum number of remote host errors getting the lock.  Is the remote host down or not accepting your credentials?" >&2
            return 1 
          fi
      fi
      continue
    fi
  done
}

if [ ! -z "$is_readlock" ]; then 
  readlock
  if [ $? -ne 0 ]; then exit 1; fi
fi
if [ ! -z "$is_grablock" ]; then 
  grablock
  if [ $? -ne 0 ]; then exit 1; fi
  [ ! -z "$debug" ] && echo '==>' "Locked $remotecommand:$remotefile with '$desiredvalue'"
fi
if [ ! -z "$is_releaselock" ]; then 
  releaselock
  if [ $? -ne 0 ]; then exit 1; fi
  [ ! -z "$debug" ] && echo '<==' "Unlocked $remotecommand:$remotefile with '$desiredvalue'"
fi
