#!/bin/bash
# The rules "init never allocates" and "no signal handler", checked three ways.
cd "$(dirname "$0")"; . ./lib.sh
N=kcos-audit-init-na-$$
tmp=$(mktemp -d); trap 'docker rm -f $N >/dev/null 2>&1; rm -rf "$tmp"' EXIT

# 1. Source: nothing in init.rs or lock.rs names the allocator, and the
# helpers they import from util.rs are the non-allocating ones.
src=../../src
ok "init.rs and lock.rs do not mention alloc, Vec, Box, String, format! or to_vec" "" \
   "$(grep -nE 'alloc|Vec|Box|String|format!|to_vec|to_owned|collect' $src/init.rs $src/lock.rs | grep -vE '^[^:]+:[0-9]+:\s*//')"
echo "   imported from util by init.rs: $(grep -n '^use crate::util' $src/init.rs | sed 's/.*util:://')"
echo "   imported from util by lock.rs: $(grep -n '^use crate::util' $src/lock.rs | sed 's/.*util:://')"

# 2. Binary: the allocator's only way to get memory is mmap (syscall 222).
# Count the instructions that load a given syscall number into any register.
# execve and rt_sigtimedwait are there to show that the method finds things.
loads() { objdump -d "$tmp/bin" | grep -cE "mov[[:space:]]+[wx][0-9]+, #0x$(printf %x $1)\b"; }
for img in kcontaineros:sealed kcontaineros; do
    docker rm -f $N >/dev/null 2>&1
    docker create --name $N $P $img >/dev/null
    docker cp -L $N:/sbin/init "$tmp/bin" 2>/dev/null
    docker rm -f $N >/dev/null
    line="execve(221) $(loads 221), rt_sigtimedwait(137) $(loads 137), rt_sigaction(134) $(loads 134), mmap(222) $(loads 222), munmap(215) $(loads 215), brk(214) $(loads 214)"
    echo "   $img, $(wc -c < "$tmp/bin" | tr -d ' ') bytes: $line"
    case $img in
      *sealed) ok "the sealed binary has no instruction loading 222, 215 or 214: it cannot ask for memory" \
                  "execve(221) 1, rt_sigtimedwait(137) 1, rt_sigaction(134) 1, mmap(222) 0, munmap(215) 0, brk(214) 0" "$line" ;;
    esac
done

# 3. Running: the only unnamed anonymous mapping of init is its one page of
# .bss (the first allocation would add a 262144-byte chunk, as the control
# shows for the shell), and it catches no signal.
maps() { timeout 30 docker exec --privileged $N /bb/busybox sh -c "while read range perms off dev ino path; do [ \"\$ino\" = 0 ] && [ -z \"\$path\" ] && echo \"anonymous \$perms \$(( 0x\${range#*-} - 0x\${range%-*} )) bytes;\"; done < /proc/$1/maps; /bb/busybox grep -E 'SigCgt|SigIgn' /proc/$1/status" | tr '\n\t' '  '; }
docker rm -f $N >/dev/null 2>&1
timeout 60 docker run -d --name $N $P -e KCOS_EXEC=/bb:/nonexistent:relative:/dev/shm -e KCOS_DEV=/dev/nothing $IMG /bb/kh rec 15 >/dev/null; sleep 1
for s in 1 2 10 34 20 21 28; do timeout 30 docker kill -s $s $N >/dev/null; done
timeout 30 docker exec $N /bb/kh orphans 500 0 >/dev/null
m=$(maps 1); echo "   PID 1 after warnings, 7 forwarded signals and 500 reaped orphans: $m"
ok "PID 1: one page of anonymous memory; no signal caught or ignored" \
   "anonymous rw-p 4096 bytes; SigIgn: 0000000000000000 SigCgt: 0000000000000000 " "$m"
timeout 30 docker exec -d $N /bin/sleep 5; sleep 0.5
spid=$(timeout 30 docker exec $N /bb/busybox sh -c 'for p in /proc/[0-9]*; do read c < $p/comm; [ "$c" = sleep ] && echo ${p#/proc/}; done')
m=$(maps $spid); echo "   control, the sleep utility of the same binary: $m"
ok "control: a utility of the same binary has the allocator's chunk" "anonymous rw-p 262144 bytes; anonymous rw-p 4096 bytes; " "${m%%Sig*}"
docker rm -f $N >/dev/null 2>&1
# Nested, while it waits for a stubborn leftover (stop_leftovers).
timeout 60 docker run -d --name $N $P --entrypoint /bb/busybox $IMG sh -c '/sbin/init -- /bb/busybox sh -c "/bb/kh stubborn 100 setsid; exit 5"; /bb/kh sleepms 100' >/dev/null; sleep 1.2
ipid=$(timeout 30 docker exec $N /bb/busybox sh -c 'for p in /proc/[0-9]*; do read c < $p/comm; [ "$c" = init ] && echo ${p#/proc/}; done')
m=$(maps $ipid); echo "   nested init (PID $ipid) during its 2 s wait: $m"
ok "nested init while stopping leftovers: the same" \
   "anonymous rw-p 4096 bytes; SigIgn: 0000000000000000 SigCgt: 0000000000000000 " "$m"
summary
