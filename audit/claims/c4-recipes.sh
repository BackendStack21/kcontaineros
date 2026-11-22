# Every recipe of the README and the page, run as written, and the "Use" and "Common questions" claims.
echo "== recipes and common questions"
BIOPT=()
ctx=$(mktemp -d)
I=kcos-audit-claims-r     # prefix of the images built here
made=""
docker rm -f kcos-audit-claims-ex >/dev/null 2>&1
docker create "${P[@]}" --name kcos-audit-claims-ex "$A" >/dev/null
docker cp -q kcos-audit-claims-ex:/bb/sc "$ctx/my-server"; cp "$ctx/my-server" "$ctx/agent-tools"
docker cp -q kcos-audit-claims-ex:/bb/busybox "$ctx/busybox"
docker rm kcos-audit-claims-ex >/dev/null
# build NAME <<Dockerfile      (context: my-server, agent-tools, busybox)
build() { made="$made $I-$1"; timeout 300 docker build -q "${P[@]}" -t "$I-$1" -f - "$ctx" 2>&1 | tail -3; }
buildlog() { made="$made $I-$1"; timeout 300 docker build "${P[@]}" -t "$I-$1" -f - "$ctx" 2>&1; }

claim U001 "R/I/L (recipe): FROM kcontaineros / COPY my-server /usr/local/bin/my-server / CMD [\"my-server\"]; a plain COPY needs no root"
build use >/dev/null <<'DOCKERFILE'
FROM kcontaineros
COPY my-server /usr/local/bin/my-server
CMD ["my-server"]
DOCKERFILE
t "the image runs the program, under init, as nobody" 0 "hello from my-server args=[] uid=65534" -- R $I-use
claim U002 "R/I (recipe): FROM kcontaineros:sealed / COPY my-server /usr/local/bin/my-server / CMD [\"my-server\"]"
build sealed >/dev/null <<'DOCKERFILE'
FROM kcontaineros:sealed
COPY my-server /usr/local/bin/my-server
CMD ["my-server"]
DOCKERFILE
t "the sealed image runs the program" 0 "hello from my-server args=[] uid=65534" -- R $I-sealed
claim U003 "R: keep init with ENTRYPOINT [\"/sbin/init\", \"--\", \"my-server\"]; (FAQ) ENTRYPOINT [\"/sbin/init\", \"--\", \"my-server\", \"--config\", \"/etc/app/config\"]"
build entry >/dev/null <<'DOCKERFILE'
FROM kcontaineros
COPY my-server /usr/local/bin/my-server
ENTRYPOINT ["/sbin/init", "--", "my-server", "--config", "/etc/app/config"]
DOCKERFILE
t "the arguments reach the program; PID 1 is init" 0 "hello from my-server args=[--config /etc/app/config] uid=65534" -- R $I-entry
claim U004 "R (FAQ recipe): USER 0 / RUN mkdir -p /etc/app && echo \"mode=production\" > /etc/app/config / USER 65534:65534; COPY and WORKDIR need no switch"
build run >/dev/null <<'DOCKERFILE'
FROM kcontaineros
USER 0
RUN mkdir -p /etc/app && echo "mode=production" > /etc/app/config
USER 65534:65534
DOCKERFILE
v "the RUN step ran with the built-in shell; the user is nobody again" "mode=production 65534" "$(R $I-run cat /etc/app/config /proc/self/status | awk 'NR==1{printf "%s ", $0} $1=="Uid:"{print $2}')"
claim U005 "R (FAQ): a RUN step fails with 'permission denied' when the user is nobody"
t "the same RUN without USER 0 fails, naming the reason" 0 "permission denied" -- \
  sh -c "printf 'FROM kcontaineros\nRUN mkdir -p /etc/app && echo x > /etc/app/config\n' | timeout 300 docker build --platform linux/arm64 -t $I-fail -f - '$ctx' 2>&1 | grep -o -m1 'permission denied'"
claim U006 "R (FAQ recipe): WORKDIR /data creates it owned by the current user, which is nobody"
build workdir >/dev/null <<'DOCKERFILE'
FROM kcontaineros
WORKDIR /data
DOCKERFILE
v "/data belongs to nobody, is the working directory, and the command can write there" "drwxr-xr-x 65534 65534 data|/data|kept|" \
  "$(R $I-workdir sh -c 'ls -l /; pwd; echo kept > /data/f; cat /data/f' | awk '$NF=="data"{print $1, $2, $3, $5; next} NF==1' | tr '\n' '|')"
claim U007 "R (FAQ recipe): USER 0 / RUN mkdir -p /var/lib/app && chown 65534:65534 /var/lib/app / USER 65534:65534"
build chown >/dev/null <<'DOCKERFILE'
FROM kcontaineros
USER 0
RUN mkdir -p /var/lib/app && chown 65534:65534 /var/lib/app
USER 65534:65534
DOCKERFILE
v "/var/lib/app belongs to nobody, who writes to it" "drwxr-xr-x 65534 65534 app|kept|" \
  "$(R $I-chown sh -c 'ls -l /var/lib; echo kept > /var/lib/app/f; cat /var/lib/app/f' | awk '{print (NF > 1) ? $1 " " $2 " " $3 " " $5 : $0}' | tr '\n' '|')"
claim U008 "R (FAQ recipe): docker run -v app-data:/data my-image: a new named volume takes over the directory's owner; on a path the image does not have it is root's and nobody cannot write"
docker volume rm -f kcos-audit-claims-vd kcos-audit-claims-ve >/dev/null 2>&1
# (An empty file: the Docker VM's disk was full for non-root users during the audit, and data blocks on a volume could not be had.)
t "volume on the prepared /data: nobody owns it and creates a file there" 0 $'drwxr-xr-x 65534 65534\nf' -- sh -c "timeout 60 docker run --rm --platform linux/arm64 -v kcos-audit-claims-vd:/data $I-workdir sh -c 'ls -l /; touch /data/f; ls /data' | awk '\$NF==\"data\"{print \$1, \$2, \$3; next} NF==1'"
t "volume on /elsewhere: not writable by nobody" 1 "sh: /elsewhere/f: permission denied" -- R -v kcos-audit-claims-ve:/elsewhere $I-workdir sh -c 'echo kept > /elsewhere/f'
docker volume rm -f kcos-audit-claims-vd kcos-audit-claims-ve >/dev/null 2>&1
claim U009 "R (FAQ recipe): docker run --tmpfs /scratch:uid=65534,gid=65534,mode=0700 my-image"
t "/scratch is writable by nobody" 0 "kept" -- R --tmpfs /scratch:uid=65534,gid=65534,mode=0700 "$IMG" sh -c 'echo kept > /scratch/f; cat /scratch/f'
claim U010 "R/I: with --read-only, /tmp, /var/tmp and /run are read-only too; (recipe) docker run --read-only --tmpfs /tmp my-image"
t "--read-only" 0 $'sh: /tmp/f: read-only file system\nsh: /var/tmp/f: read-only file system\nrc=1' -- R --read-only "$IMG" sh -c 'exec 2>&1; echo x > /tmp/f; echo x > /var/tmp/f; echo "rc=$?"'
t "--read-only --tmpfs /tmp" 0 "kept" -- R --read-only --tmpfs /tmp "$IMG" sh -c 'echo kept > /tmp/f; cat /tmp/f'
claim U011 "R (FAQ): cannot be made writable: anything under /bin, /sbin, /usr or the top-level directory of a KCOS_EXEC entry, even as a volume or tmpfs mounted there"
docker volume rm -f kcos-audit-claims-vu >/dev/null 2>&1
t "tmpfs and a volume mounted below /usr, owned by nobody: not writable under init" 0 $'sh: /usr/local/data/f: permission denied\nsh: /usr/vol/f: permission denied\nrc=1' -- \
  R --tmpfs /usr/local/data:uid=65534,gid=65534,mode=0700 -v kcos-audit-claims-vu:/usr/vol "$IMG" sh -c 'exec 2>&1; echo x > /usr/local/data/f; echo x > /usr/vol/f; echo "rc=$?"'
tc "the tmpfs without init is writable" 0 "rc=0" -- R --tmpfs /usr/local/data:uid=65534,gid=65534,mode=0700 --entrypoint /bin/sh "$IMG" -c 'echo x > /usr/local/data/f; echo "rc=$?"'
docker volume rm -f kcos-audit-claims-vu >/dev/null 2>&1
claim U012 "R/I: ENV KCOS_EXEC=/app names a program directory; several are separated by colons (/app:/opt/tool/bin); its top-level directory stops being writable, so a program in /app/bin cannot keep its data in /app/data"
build app >/dev/null <<'DOCKERFILE'
FROM kcontaineros
COPY --chown=65534:65534 my-server /app/bin/my-server
COPY --chown=65534:65534 my-server /opt/tool/bin/tool
COPY --chown=65534:65534 my-server /srv/elsewhere/prog
WORKDIR /app/data
WORKDIR /opt/data
WORKDIR /
ENV KCOS_EXEC=/app/bin:/opt/tool/bin
DOCKERFILE
t "programs in both directories start, one elsewhere does not; /app/data and /opt/data, owned by nobody, are not writable" 0 \
  $'hello from my-server args=[] uid=65534\nhello from tool args=[] uid=65534\nsh: /srv/elsewhere/prog: permission denied\nsh: /app/data/f: permission denied\nsh: /opt/data/f: permission denied\nrc=1' -- \
  R $I-app sh -c 'exec 2>&1; /app/bin/my-server; /opt/tool/bin/tool; /srv/elsewhere/prog; echo x > /app/data/f; echo x > /opt/data/f; echo "rc=$?"'
tc "without KCOS_EXEC the programs do not start and the data directories are writable" 0 $'sh: /app/bin/my-server: permission denied\nrc=0' -- \
  R -e KCOS_EXEC= $I-app sh -c 'exec 2>&1; /app/bin/my-server; echo x > /app/data/f; echo "rc=$?"'
claim U013 "R/I: KCOS_EXEC entries must be plain absolute paths to real directories: /, a trailing slash, . or .. components and anything reached through a symbolic link are ignored, with a warning; nothing in /dev, /proc or /sys can be a program directory"
W1='is not a plain absolute path: ignored'; W2='is not a directory (symbolic links are not followed): ignored'; W3='cannot hold programs: ignored'
t "one container with every kind of unusable entry" 0 \
"kcontaineros: warning: KCOS_EXEC: / $W1
kcontaineros: warning: KCOS_EXEC: /app/bin/ $W1
kcontaineros: warning: KCOS_EXEC: /app/./bin $W1
kcontaineros: warning: KCOS_EXEC: /app/../app/bin $W1
kcontaineros: warning: KCOS_EXEC: relative $W1
kcontaineros: warning: KCOS_EXEC: /dev/shm $W3
kcontaineros: warning: KCOS_EXEC: /proc/self $W3
kcontaineros: warning: KCOS_EXEC: /sys/kernel $W3
kcontaineros: warning: KCOS_EXEC: /var/run $W2
sh: /app/bin/my-server: permission denied" -- \
  R -e KCOS_EXEC=/:/app/bin/:/app/./bin:/app/../app/bin:relative:/dev/shm:/proc/self:/sys/kernel:/var/run $I-app sh -c '/app/bin/my-server 2>&1; true'
claim U014 "R/I: the top-level directory of an ignored entry is not writable all the same"
t "KCOS_EXEC=/app/nonexistent (ignored: no such directory): /app/data is not writable" 1 "kcontaineros: warning: KCOS_EXEC: /app/nonexistent $W2
sh: /app/data/f: permission denied" -- R -e KCOS_EXEC=/app/nonexistent $I-app sh -c 'echo x > /app/data/f'
for e in /app/bin/ /app/./bin /app/../app/bin; do
  t "KCOS_EXEC=$e (ignored: not a plain path): /app/data is not writable" 1 "kcontaineros: warning: KCOS_EXEC: $e $W1
sh: /app/data/f: permission denied" -- R -e "KCOS_EXEC=$e" $I-app sh -c 'echo x > /app/data/f'
done
claim U015 "R/I: new top-level directories cannot be created at run time (mkdir /new fails); as root too"
t "nobody" 1 "mkdir: /new: permission denied" -- R "$IMG" mkdir /new
t "root (it owns /, mode 0755 in a container)" 1 "mkdir: /new: permission denied" -- R --user 0 "$IMG" mkdir /new
tc "root without init" 0 "" -- R --user 0 --entrypoint /bin/mkdir "$IMG" /new
claim U016 "R/I: out of the box only /tmp and /var/tmp qualify as writable, plus the /dev/shm that Docker mounts unless started with --ipc none"
PROBE='for d in $(/bb/busybox find / -xdev -type d 2>/dev/null) /dev /dev/shm /dev/mqueue /dev/pts /proc /sys /sys/fs/cgroup; do (: > "$d/.kcos-audit") 2>/dev/null && { echo "$d"; /bb/busybox rm -f "$d/.kcos-audit"; }; done | /bb/busybox sort | /bb/busybox tr "\n" " "'
t "as nobody: every directory of the image and of /dev, /proc, /sys where a file can be created" 0 "/dev/shm /tmp /var/tmp " -- R "${NOBODY[@]}" "$A" /bb/busybox sh -c "$PROBE"
t "  with --ipc none" 0 "/tmp /var/tmp " -- R "${NOBODY[@]}" --ipc none "$A" /bb/busybox sh -c "$PROBE"
t "  as root (not privileged)" 0 "/dev/shm /tmp /var/tmp " -- R --user 0 "$A" /bb/busybox sh -c "$PROBE"
claim U017 "R/I: in the sealed image there is no /tmp; mount one: --tmpfs /tmp:uid=65534,gid=65534,mode=0700"
build sealedbb >/dev/null <<'DOCKERFILE'
FROM kcontaineros:sealed
COPY agent-tools /usr/local/bin/agent-tools
COPY busybox /usr/local/bin/busybox
COPY my-server /usr/local/bin/sc
CMD ["agent-tools"]
DOCKERFILE
t "sealed: no /tmp" 0 "missing" -- R $I-sealedbb busybox sh -c '[ -e /tmp ] || echo missing'
t "sealed with the tmpfs: writable by nobody" 0 "kept" -- R --tmpfs /tmp:uid=65534,gid=65534,mode=0700 $I-sealedbb busybox sh -c 'echo kept > /tmp/f && busybox cat /tmp/f'
t "sealed: no directory where nobody can create a file (--ipc none)" 0 "" -- R --ipc none $I-sealedbb busybox sh -c "${PROBE//\/bb\/busybox/busybox}"
claim U018 "R/I: sealed: no shell, no utilities; the binary is init whatever it is called"
t "docker run kcontaineros:sealed (no command): there is no /bin/sh" 127 "kcontaineros: /bin/sh: no such file or directory" -- R "$SEALED"
t "started under the name sh it is still init" 127 "kcontaineros: -c: no such file or directory" -- R $I-sealedbb busybox sh -c 'exec -a sh /sbin/init -c "echo shell"'
t "started under the name ls, cat, kcontaineros: still init (it tries to run its argument)" 0 "kcontaineros: /nonexistent: no such file or directory|kcontaineros: /nonexistent: no such file or directory|kcontaineros: --list: no such file or directory|" -- \
  R $I-sealedbb busybox sh -c '(exec -a ls /sbin/init /nonexistent) 2>&1 | busybox tr "\n" "|"; (exec -a cat /sbin/init /nonexistent) 2>&1 | busybox tr "\n" "|"; (exec -a kcontaineros /sbin/init --list) 2>&1 | busybox tr "\n" "|"'
t "sealed: the lockdown is the same (as nobody the bounding set cannot be emptied)" 0 $'CapInh:\t0000000000000000\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2\nerrno=1' -- \
  R $I-sealedbb busybox sh -c 'busybox grep -E "^(Cap(Inh|Prm|Eff|Amb)|NoNewPrivs|Seccomp):" /proc/self/status; sc 279 s:x 0'

claim U019 "R/I (recipe): docker run -i --rm --read-only --network none --ipc none --memory 512m --pids-limit 128 --tmpfs /work:uid=65534,gid=65534,mode=0700 my-agent-tools: writes to /work and nowhere else, cannot start anything it writes there, has no network, holds no privilege"
AG=(-i --rm --read-only --network none --ipc none --memory 512m --pids-limit 128 --tmpfs /work:uid=65534,gid=65534,mode=0700)
t "the recipe as written" 0 "hello from agent-tools args=[] uid=65534" -- timeout 120 docker run "${P[@]}" "${AG[@]}" $I-sealedbb
t "directories where a file can be created" 0 "/work " -- timeout 120 docker run "${P[@]}" "${AG[@]}" $I-sealedbb busybox sh -c "${PROBE//\/bb\/busybox/busybox}"
t "a program written to /work does not start; no address but loopback and no route; no capability" 0 $'exec=126\naddresses: 127.0.0.1/8 ::1/128 \nroutes: 0\nCapEff:\t0000000000000000' -- \
  timeout 120 docker run "${P[@]}" "${AG[@]}" $I-sealedbb busybox sh -c 'busybox cp /usr/local/bin/sc /work/prog; /work/prog 172 2>/dev/null; echo "exec=$?"; echo "addresses: $(busybox ip -o addr | busybox awk "{printf \"%s \", \$4}")"; echo "routes: $(busybox ip route | busybox wc -l)"; busybox grep CapEff /proc/self/status'
claim U020 "R/I: without --ipc none Docker gives every container a writable /dev/shm of 64 MB"
t "size of /dev/shm in a default container, in kB; nobody can write there" 0 "65536 written" -- R "${NOBODY[@]}" "$A" /bb/busybox sh -c 'echo "$(/bb/busybox df -k /dev/shm | /bb/busybox awk "NR==2{print \$2}") $(echo x > /dev/shm/f && echo written)"'
claim U021 "R (FAQ): a dynamically linked program fails with 'no such file or directory' ('not found' from the shell)"
build dyn >/dev/null <<'DOCKERFILE'
FROM alpine:latest AS a
FROM kcontaineros
COPY --from=a /bin/busybox /usr/local/bin/dyn
COPY --from=a /lib/ld-musl-aarch64.so.1 /usr/lib/ld-musl-aarch64.so.1
COPY busybox /usr/local/bin/busybox
DOCKERFILE
t "from init" 127 "kcontaineros: dyn: no such file or directory" -- R $I-dyn dyn
t "from the shell" 127 "sh: dyn: not found" -- R $I-dyn sh -c dyn
claim U022 "R/I (limit): a dynamic loader you ship is a program that loads programs: it will map and run a binary from any directory not mounted noexec"
t "the loader in /usr/lib runs a dynamically linked binary copied to /tmp at run time" 0 "ran-from-tmp" -- R $I-dyn sh -c 'cp /usr/local/bin/dyn /tmp/busybox; /usr/lib/ld-musl-aarch64.so.1 /tmp/busybox echo ran-from-tmp'
t "  not from a tmpfs mounted by --tmpfs (noexec)" 1 "/usr/lib/ld-musl-aarch64.so.1: /tmp/busybox: Not a valid dynamic program" -- \
  R --tmpfs /tmp $I-dyn sh -c 'cp /usr/local/bin/dyn /tmp/busybox; /usr/lib/ld-musl-aarch64.so.1 /tmp/busybox echo ran-from-tmp'
claim U023 "R (FAQ): how to check that the lockdown is active: docker run --rm my-image cat /proc/self/status; look for NoNewPrivs: 1, Seccomp: 2 and CapEff: 0000000000000000"
v "the three lines (tab shown as a space)" "CapEff: 0000000000000000|NoNewPrivs: 1|Seccomp: 2|" "$(R $I-use cat /proc/self/status | grep -E '^(NoNewPrivs|Seccomp|CapEff):' | tr '\t' ' ' | tr '\n' '|')"
claim U024 "R: ports below 1024 work for any user; --cap-add and --privileged have no effect on the command"
t "nobody listens on port 80" 0 "listening" -- R "${NOBODY[@]}" "$A" /bb/busybox sh -c '/bb/busybox nc -l -p 80 2>/dev/null & /bb/busybox sleep 0.5; /bb/busybox netstat -ltn | /bb/busybox grep -q ":80 " && echo listening; kill $!'
claim U025 "R (FAQ): a program that starts as root and switches user itself will fail to switch"
t "setuid(65534) and setgid(65534) as root under init" 0 $'errno=1\nerrno=1' -- R --user 0 "$A" /bb/busybox sh -c '/bb/sc 146 65534; /bb/sc 144 65534'
tc "without init" 0 "ret=0" -- R --user 0 --entrypoint /bb/sc "$A" 144 65534
claim U026 "R (FAQ recipe, second stage only: 'apk add' needs the network and was not run): COPY --from=certs ... /etc/ssl/certs/ and /usr/share/zoneinfo need no USER switch"
build certs >/dev/null <<'DOCKERFILE'
FROM kcos-audit-claims-img AS certs
RUN ["/bb/busybox", "sh", "-c", "/bb/busybox mkdir -p /c/ssl/certs /c/zoneinfo && echo CERT > /c/ssl/certs/ca-certificates.crt && echo TZ > /c/zoneinfo/UTC"]
FROM kcontaineros
COPY --from=certs /c/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=certs /c/zoneinfo /usr/share/zoneinfo
DOCKERFILE
t "the files are in place and readable by nobody" 0 $'CERT\nTZ' -- R $I-certs cat /etc/ssl/certs/ca-certificates.crt /usr/share/zoneinfo/UTC
claim U027 "R: examples/hello-http is a complete image: a Rust HTTP server on the image, built with a shell-form RUN"
made="$made $I-http"
if timeout 600 docker build -q "${P[@]}" -t $I-http examples/hello-http >/dev/null 2>&1; then
  docker rm -f kcos-audit-claims-web >/dev/null 2>&1
  timeout 60 docker run -d "${P[@]}" --name kcos-audit-claims-web -p 127.0.0.1::8080 $I-http >/dev/null
  port=$(docker port kcos-audit-claims-web 8080 | sed 's/.*://')
  body=""; for _ in $(seq 1 30); do body=$(curl -fsS --max-time 2 "http://127.0.0.1:$port/" 2>/dev/null) && break; sleep 0.2; done
  v "the server answers on 127.0.0.1" "Hello from kContainerOS" "$body"
  v "PID 1 is init, the server its command, the user nobody, the RUN layer present" "/sbin/init hello-http 65534 ready" "$(docker exec kcos-audit-claims-web ps | awk '$1==1{printf "%s %s ", $3, $4}')$(docker exec kcos-audit-claims-web cat /proc/1/status | awk '$1=="Uid:"{printf "%s ", $2}')$(docker exec kcos-audit-claims-web cat /data/status)"
  t0=$(python3 -c 'import time; print(int(time.time()*1000))'); docker stop kcos-audit-claims-web >/dev/null; t1=$(python3 -c 'import time; print(int(time.time()*1000))')
  v "I (Stopping): a server with no signal handling stops as soon as docker stop sends SIGTERM, status 143 ($((t1 - t0)) ms)" "143 yes" "$(docker inspect -f '{{.State.ExitCode}}' kcos-audit-claims-web) $([ $((t1 - t0)) -lt 1000 ] && echo yes || echo no)"
  docker rm -f kcos-audit-claims-web >/dev/null 2>&1
else v "examples/hello-http builds" yes no; fi
claim U028 "R: linux/amd64 and others: docker build stops with an error"
t "docker build --platform linux/amd64 ." 0 "nonzero kContainerOS supports linux/arm64 only (got linux/amd64)" -- \
  sh -c 'out=$(timeout 600 docker build --platform linux/amd64 . 2>&1); rc=$?; echo "$([ $rc -ne 0 ] && echo nonzero) $(printf "%s" "$out" | grep -o "kContainerOS supports linux/arm64 only (got linux/amd64)" | head -1)"'
claim U029 "R: pinned and reproducible: a rebuild from scratch produces the identical image layer (and the sealed target the identical sealed layer)"
made="$made $I-repro $I-repro-sealed"
timeout 900 docker build -q --no-cache "${P[@]}" -t $I-repro . >/dev/null 2>&1
timeout 900 docker build -q "${P[@]}" --target sealed -t $I-repro-sealed . >/dev/null 2>&1
v "docker build --no-cache of this checkout against the prepared kcontaineros image: layers" "$(docker image inspect -f '{{json .RootFS.Layers}}' "$IMG")" "$(docker image inspect -f '{{json .RootFS.Layers}}' $I-repro 2>&1)"
v "--target sealed against the prepared kcontaineros:sealed: layers" "$(docker image inspect -f '{{json .RootFS.Layers}}' "$SEALED")" "$(docker image inspect -f '{{json .RootFS.Layers}}' $I-repro-sealed 2>&1)"
docker rmi -f $made $I-fail >/dev/null 2>&1
rm -rf "$ctx"
