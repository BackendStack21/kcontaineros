#!/bin/sh
# KCOS_EXEC: how init turns the value into rules. Run from the repo root after build.sh.
# Each case starts a container whose PID 1 is busybox, builds the value with
# printf (so that any byte can be in it) and exec()s /sbin/init with exactly
# that environment: init is PID 1, as root, as `docker run` would start it.
# The check then reports, under that init:
#   x:  execve of /app/bin/lp, /w/lp, /w/bin/lp, a copy made in /tmp, and (if given) an extra path
#   w:  creating a file in /w, /app/data, /tmp, /opt   (all four are writable by mode for root or 1777)
IMG=kcos-audit-landlock-img
r() { timeout 120 docker run --rm --platform linux/arm64 -u 0:0 "$@"; }
CHECK='L=/bb/lp; $L copy /bb/lp /tmp/c >/dev/null 2>&1; $L chmod 755 /tmp/c >/dev/null 2>&1
echo "   x: /app/bin/lp=$($L exec /app/bin/lp) /w/lp=$($L exec /w/lp) /w/bin/lp=$($L exec /w/bin/lp) /tmp/c=$($L exec /tmp/c)${X:+ extra=$($L exec "$X")}"
echo "   w: /w=$($L open c /w/n) /app/data=$($L open c /app/data/n) /tmp=$($L open c /tmp/n) /opt=$($L open c /opt/n)"'
n=0
case_() { # DESCRIPTION  PRINTF-FORMAT-OF-VALUE  [EXTRA-PATH-PRINTF]
    n=$((n+1)); echo "[$n] KCOS_EXEC=$1"
    r --entrypoint /bb/busybox -e "CHECK=$CHECK" $IMG sh -c '
        v=$(printf "$1"); X=$(printf "$2"); export X
        exec /bb/lp initenv "KCOS_EXEC=$v" "X=$X" -- /bb/busybox sh -c "$CHECK"' sh "$2" "${3:-}" 2>&1 | /usr/bin/cut -c1-330
}
case_ '/bb:/app/bin (plain)'                         '/bb:/app/bin'
case_ '/bb:/app/bin/ (trailing slash)'               '/bb:/app/bin/'
case_ '/bb:/w/ (trailing slash)'                     '/bb:/w/'
case_ '/bb:/lnk/bin (/lnk -> /app)'                  '/bb:/lnk/bin'
case_ '/bb:/app/binlink (-> bin)'                    '/bb:/app/binlink'
case_ '/bb:/app/wlink (-> /w/bin)'                   '/bb:/app/wlink'
case_ '/bb:/w/applink (-> /app/bin)'                 '/bb:/w/applink'
case_ '/bb:/'                                        '/bb:/'
case_ '/bb:/app/./bin'                               '/bb:/app/./bin'
case_ '/bb:/app/../w'                                '/bb:/app/../w'
case_ '/bb://w'                                      '/bb://w'
case_ '/bb:/app//bin'                                '/bb:/app//bin'
case_ '/bb:w'                                        '/bb:w'
case_ '/bb:./w'                                      '/bb:./w'
case_ '/bb: (empty last entry)'                      '/bb:'
case_ ':/bb (empty first entry)'                     ':/bb'
case_ '/bb::/app/bin (empty middle entry)'           '/bb::/app/bin'
case_ '/bb:/app/bin:/app/bin:/app/bin (repeated)'    '/bb:/app/bin:/app/bin:/app/bin'
case_ '/bb:/proc/self/root/w'                        '/bb:/proc/self/root/w' '/proc/self/root/w/lp'
case_ '/bb:/proc/1/root/w'                           '/bb:/proc/1/root/w'
case_ '/bb:/dev/shm'                                 '/bb:/dev/shm'
case_ '/bb:/dev'                                     '/bb:/dev'
case_ '/bb:/sys'                                     '/bb:/sys'
case_ '/bb:/proc'                                    '/bb:/proc'
case_ '/bb:/devx (does not exist)'                   '/bb:/devx'
case_ '/bb:/tmp'                                     '/bb:/tmp'
case_ '/bb:/w'                                       '/bb:/w'
case_ '/bb:/w/bin'                                   '/bb:/w/bin'
case_ '/bb:/topfile (a regular file)'                '/bb:/topfile'
case_ '/bb:/bb/lp (a file in a program directory)'   '/bb:/bb/lp'
case_ '/bb:/app/\377\376bin (not UTF-8)'             '/bb:/app/\377\376bin' '/app/\377\376bin/lp'
case_ '/bb:/app/sp ace'                              '/bb:/app/sp ace' '/app/sp ace/lp'
z255=$(printf '%0255d' 0)
case_ '/bb:/app/<255 x 0> (longest name a filesystem takes)' "/bb:/app/$z255" "/app/$z255/lp"
case_ '/bb:/app/<256 x 0>'                           "/bb:/app/0$z255"
case_ '/app/bin:/bb (order)'                         '/app/bin:/bb'
case_ '(empty value: /bb is no program directory, the check cannot start)' ''
case_ '/w (only: the check cannot start)'            '/w'

echo "[big-1] one entry of 60 008 bytes (/app/bin followed by 30 000 x /x), then :/bb"
r --entrypoint /bb/busybox -e "CHECK=$CHECK" $IMG sh -c '
    v=/app/bin$(/bb/busybox awk "BEGIN{for(i=0;i<30000;i++)printf \"/x\"}"):/bb
    exec /bb/lp initenv "KCOS_EXEC=$v" -- /bb/busybox sh -c "$CHECK"' 2>&1 | /usr/bin/awk '{ if (length($0) > 300) print "   (line of " length($0) " bytes) " substr($0,1,90) " ... " substr($0, length($0)-60); else print }'
for count in 5000 12000; do
echo "[big-$count] $count x /app/bin, then /bb  (and $count x /nonexistent, warnings counted)"
r --entrypoint /bb/busybox -e "CHECK=$CHECK" $IMG sh -c '
    v=$(/bb/busybox awk "BEGIN{for(i=0;i<'$count';i++)printf \"/app/bin:\"}")/bb
    s=$(/bb/busybox date +%s); /bb/lp initenv "KCOS_EXEC=$v" -- /bb/busybox sh -c "$CHECK"; echo "   seconds: $(( $(/bb/busybox date +%s) - s ))"
    v=$(/bb/busybox awk "BEGIN{for(i=0;i<'$count';i++)printf \"/nonexist:\"}")/bb
    /bb/lp initenv "KCOS_EXEC=$v" -- /bb/lp exec /app/bin/lp 2>/tmp/err; echo "   warning lines: $(/bb/busybox wc -l < /tmp/err)"' 2>&1 | /usr/bin/cut -c1-300
done

echo "[dup-1] two KCOS_EXEC variables: first /bb, second /bb:/w   (the first counts)"
r --entrypoint /bb/lp -e "CHECK=$CHECK" $IMG initenv KCOS_EXEC=/bb KCOS_EXEC=/bb:/w -- /bb/busybox sh -c "$CHECK" 2>&1
echo "[dup-2] two KCOS_EXEC variables: first /bb:/w, second /bb"
r --entrypoint /bb/lp -e "CHECK=$CHECK" $IMG initenv KCOS_EXEC=/bb:/w KCOS_EXEC=/bb -- /bb/busybox sh -c "$CHECK" 2>&1
echo "[plain-docker] the same as case 2 and 3 through docker -e, no wrapper"
r -e KCOS_EXEC=/bb:/app/bin/:/w/ -e "CHECK=$CHECK" $IMG /bb/busybox sh -c "$CHECK" 2>&1
echo "[nested] under init, a second init with KCOS_EXEC=/bb:/w and with KCOS_DEV cannot widen anything"
r -e KCOS_EXEC=/bb --device /dev/rtc0 $IMG /bb/lp initenv KCOS_EXEC=/bb:/w KCOS_DEV=/dev/rtc0 -- /bb/busybox sh -c 'echo "   /w/lp=$(/bb/lp exec /w/lp) rtc0 write=$(/bb/lp open w /dev/rtc0)"' 2>&1
echo "[nofile] RLIMIT_NOFILE too small for init to build its rules (set by a wrapper: runc itself needs more)"
for lim in 3 4 5 6 7 8; do
  printf '   ulimit -n %s: ' $lim
  r --entrypoint /bb/busybox $IMG sh -c "ulimit -n $lim; exec /sbin/init -- /bb/lp exec /w/lp" 2>&1 | /usr/bin/tr '\n' ' '; echo
done
