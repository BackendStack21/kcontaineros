# Runs inside a container (busybox sh). W is a writable directory.
# Every route tries to start /opt/evil after copying it to W at run time.
W=${W:-/tmp}
B=${B:-/bb}            # a program directory holding kp and busybox
export PATH=$B:$PATH
r() { n=$1; shift; out=$("$@" 2>&1); echo "[$n] status=$? :: $(echo "$out" | tr '\n' '|')"; }
cd /
cp /opt/evil $W/evil && chmod 755 $W/evil || echo "SETUP FAILED in $W"
printf '#!/bin/sh\necho SCRIPT-RAN\n' > $W/script.sh; chmod 755 $W/script.sh
printf 'echo NOSHEBANG-RAN\n' > $W/plain; chmod 755 $W/plain
printf '#!%s/evil\n' $W > $W/interp; chmod 755 $W/interp
ln -s $W/evil $W/link 2>/dev/null
r direct            $W/evil
r path-lookup       env PATH=$W evil
[ -e /bin/kcontaineros ] && r kcos-env          /bin/env $W/evil
[ -e /bin/kcontaineros ] && r kcos-sh-c         /bin/sh -c "$W/evil"
[ -e /bin/kcontaineros ] && r kcos-sh-exec      /bin/sh -c "exec $W/evil"
[ -e /bin/kcontaineros ] && r kcos-sh-command   /bin/sh -c "command $W/evil; echo after=\$?"
[ -e /bin/kcontaineros ] && r kcos-sh-PATH      /bin/sh -c "PATH=$W; evil"
[ -e /bin/kcontaineros ] && r kcos-sh-PATH-plain /bin/sh -c "PATH=$W; plain"
r symlink           $W/link
r shebang-script    $W/script.sh
[ -e /bin/kcontaineros ] && r kcos-noshebang    /bin/sh -c "$W/plain"
r interp-is-evil    $W/interp
r proc-self-root    /proc/self/root$W/evil
r proc-1-root       /proc/1/root$W/evil
r proc-self-cwd     sh -c "cd $W && /proc/self/cwd/evil"
r relative          sh -c "cd $W && ./evil"
r dev-fd            sh -c "exec 7<$W/evil; /dev/fd/7"
r proc-fd           sh -c "exec 7<$W/evil; /proc/self/fd/7"
r execveat-empty    kp execveat $W/evil
r fexec             kp fexec $W/evil
r o_tmpfile         kp tmpfile $W
r memfd             kp memfd
r sysv-shm-mapfiles kp shmexec $W/evil
r hardlink-into-bb  ln $W/evil $B/evil
r rename-into-bb    mv $W/evil $B/evil
r copy-into-bb      cp $W/evil $B/evil
[ -e /bin/kcontaineros ] && r copy-into-usr     cp $W/evil /usr/local/bin/evil
r symlink-into-bb   ln -s $W/evil $B/evil2
r overwrite-tool    sh -c "cat $W/evil > $B/kp"
r append-tool       sh -c ": >> $B/kp"
r unlink-tool       rm -f $B/kp
r mkdir-in-bb       mkdir $B/newdir
r rename-tool       mv $B/kp $B/kp2
[ -e /bin/kcontaineros ] && r LD_PRELOAD        env LD_PRELOAD=$W/evil LD_LIBRARY_PATH=$W LD_AUDIT=$W/evil /bin/true
r argv0-init        kp argv0 /proc/self/exe hello
[ -e /bin/kcontaineros ] && r reexec-kcos-argv0-sh kp argv0 /bin/kcontaineros sh -c "echo as-sh; $W/evil"
[ -e /bin/kcontaineros ] && r nested-init       env KCOS_EXEC=$W /bin/kcontaineros init -- $W/evil
r nested-init-argv0 env KCOS_EXEC=$W kp argv0 /proc/1/exe init $W/evil
echo "--- documented as possible (interpretation, in-process code)"
[ -e /bin/kcontaineros ] && r kcos-sh-FILE      /bin/sh $W/script.sh
[ -e /bin/kcontaineros ] && r kcos-sh-stdin     sh -c "/bin/sh < $W/script.sh"
r mmap-file-exec    kp mapexec /opt/payload.bin
r anon-exec         kp anonexec /opt/payload.bin
cp /opt/payload.bin $W/payload.bin
r mmap-written-file kp mapexec $W/payload.bin
r anon-written-file kp anonexec $W/payload.bin
rm -f $W/evil $W/script.sh $W/plain $W/interp $W/link $W/payload.bin 2>/dev/null
