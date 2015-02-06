# sshlock
Mutexes/locking via ssh between servers

```
Usage: sshlock.sh --remotecommand 'ssh remotehost' 
  --file /root/lock.file 
  --key $(hostname) .  some unique value that identifies you as the holding process.  e.g. 
    a server hostname.  when you release the lock you need 
    to use the same key as you did with the lock.  The key should not be something another 
    process contending for the lock would use.
  acquire 
  release 
  read.  Grab release or read the lock (one or more of these)
  [--maxwait 60 ].  to wait a maxiumum of 60 seconds for the lock, else getlock will return an error
  [--maxremotehosterrors number ].  exit after seeing this many errors from the remotecommand.  
    e.g. if that remote server is not up or not accepting your credentials.
  [ --debug | -v | -vv ].  Output debug info to stderr
  [ --progress ].  Output wait progress. 
```

# Examples:
```
# reading when no prior lock exists
[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo read
Readlock: ssh host987:/tmp/foo:No file: /tmp/foo

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo \
  acquire --key 'secret'
# lock is acquired here

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo \
  --key 'badsecret' --progress --maxwait 20 acquire 
Waiting for a server lock on ssh host987:/tmp/foo currently in use by 'secret'
Get lock timed out
[root@hosta xen]# echo 0
1
# lock was not reacquired since the secret did not match


[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo \
  --key 'secret' --progress acquire 
# lock is reacquired ok (since we already hold it/that secret)

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo read
Readlock: ssh host987:/tmp/foo:secret

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo \
  --key 'badsecret' release  
Key did not match, nothing to release.
# releasing the lock with the wrong secret returns immediately

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo \
  --key 'secret' release  
# releases ok

[root@hosta xen]# sshlock.sh --remotecommand 'ssh hostb'  --file /tmp/foo \
  --key 'secret' release  
# didn't have the lock, release it again no problems
```

If you are scripting this, then you will likely need an ssh-agent and keys.  Running the following prior to sshlock.sh should work well:
```
SSHAGENT=/usr/bin/ssh-agent
  SSHAGENTARGS="-s"
  if [ -z "/private/tmp/com.apple.launchd.NcipAMBTkv/Listeners" -a -x "" ]; then
    eval 
    echo "Creating an aget "
    trap "kill  && echo killing agent " 0
  fi
  # add a passwordless private key file
  ssh-add -l | grep -qai 'somekeyname' || ssh-add somekey.private.key
```
