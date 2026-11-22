# "Compared with Alpine": every number of the table, measured again on this machine.
echo "== compared with Alpine"
AL=alpine:latest
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
claim A001 "R: both were measured on the same machine: Alpine 3.24.4 and kContainerOS 0.2.0 on Docker 29.9.3, linux/arm64"
v "the local alpine:latest, the image's version, the Docker server" "3.24.4 0.2.0 29.9.3 linux/arm64" \
  "$(R $AL cat /etc/alpine-release) $(R "$IMG" kcontaineros --version | cut -d' ' -f2) $(docker version --format '{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}')"
claim A002 "R: Alpine image size (docker images) 13.6 MB; root filesystem layer 9.31 MB"
v "docker images / docker history" "13.6MB 9.31MB" "$(docker images --format '{{.Size}}' $AL) $(docker history --format '{{.Size}}' $AL | grep -v '^0B' | head -1)"
claim A003 "R: kContainerOS is more than 50 times smaller"
a=$(docker image inspect -f '{{.Size}}' $AL); k=$(docker image inspect -f '{{.Size}}' "$IMG")
v "ratio of the two image sizes ($a / $k = $((a / k)))" yes "$([ $((a / k)) -ge 50 ] && echo yes || echo no)"
claim A004 "R: Alpine userland: busybox, 919 kB; 304 busybox applets; musl, 723 kB; apk, 16 packages installed"
v "size of /bin/busybox in kB, applets, size of musl in kB, packages" "919 304 723 16" \
  "$(R $AL sh -c 'echo "$(( ($(wc -c < /bin/busybox) + 500) / 1000 )) $(busybox --list | wc -l) $(( ($(wc -c < /lib/ld-musl-aarch64.so.1) + 500) / 1000 )) $(apk info 2>/dev/null | wc -l)"')"
claim A005 "R: Alpine: CA certificates yes; timezone data no; dynamically linked binaries yes; PID 1 is your command itself"
v "ca-certificates.crt present, /usr/share/zoneinfo absent, ldd /bin/busybox names the musl loader, PID 1 of 'cat /proc/1/comm' is cat" "certs=yes tz=no dynamic=yes pid1=cat" \
  "$(R $AL sh -c 'echo "certs=$([ -s /etc/ssl/certs/ca-certificates.crt ] && echo yes || echo no) tz=$([ -e /usr/share/zoneinfo ] && echo yes || echo no) dynamic=$(ldd /bin/busybox 2>&1 | grep -q "ld-musl-aarch64.so.1" && echo yes || echo no)"') pid1=$(R $AL cat /proc/1/comm)"
claim A006 "R: docker stop on sleep 300: kContainerOS 0.11 s, exit 143; Alpine 3.2 s, exit 137 (this Docker's default); 10.2 s with -t 10; docker run --init gives Alpine the same behaviour"
stopit() { # IMAGE STOP-OPTIONS RUN-OPTIONS -> "ms exitcode"
  docker rm -f kcos-audit-claims-st >/dev/null 2>&1
  timeout 60 docker run -d "${P[@]}" $3 --name kcos-audit-claims-st "$1" sleep 300 >/dev/null; sleep 1
  local t0 t1; t0=$(ms); docker stop $2 kcos-audit-claims-st >/dev/null; t1=$(ms)
  echo "$((t1 - t0)) $(docker inspect -f '{{.State.ExitCode}}' kcos-audit-claims-st)"; docker rm -f kcos-audit-claims-st >/dev/null 2>&1
}
k=$(stopit "$IMG" "" ""); a=$(stopit $AL "" ""); a10=$(stopit $AL "-t 10" ""); ai=$(stopit $AL "" "--init")
echo "        measured (ms, exit status): kContainerOS $k | Alpine $a | Alpine -t 10: $a10 | Alpine --init: $ai"
printf 'kcontaineros %s\nalpine %s\nalpine-t10 %s\nalpine-init %s\n' "$k" "$a" "$a10" "$ai" > "$OUT/stop-compare.txt"
v "kContainerOS: under 0.5 s, exit 143" "yes 143" "$([ ${k% *} -lt 500 ] && echo yes || echo no) ${k#* }"
v "Alpine: 3.2 s give or take 0.5, exit 137" "yes 137" "$([ ${a% *} -gt 2700 ] && [ ${a% *} -lt 3700 ] && echo yes || echo "no (${a% *} ms)") ${a#* }"
v "Alpine with -t 10: 10.2 s give or take 0.5, exit 137" "yes 137" "$([ ${a10% *} -gt 9700 ] && [ ${a10% *} -lt 10700 ] && echo yes || echo "no (${a10% *} ms)") ${a10#* }"
v "Alpine with --init: under 0.5 s, exit 143" "yes 143" "$([ ${ai% *} -lt 500 ] && echo yes || echo no) ${ai#* }"
claim A007 "R: docker run --rm IMAGE true, 7 runs: kContainerOS 170 to 192 ms, Alpine 172 to 258 ms; the difference is within noise"
runs() { local out="" t0 t1 i; for i in 1 2 3 4 5 6 7; do t0=$(ms); timeout 60 docker run --rm "${P[@]}" "$1" true; t1=$(ms); out="$out $((t1 - t0))"; done; echo "$out"; }
rk=$(runs "$IMG"); ra=$(runs $AL)
echo "        measured, ms: kContainerOS:$rk | Alpine:$ra"
printf 'kcontaineros%s\nalpine%s\n' "$rk" "$ra" > "$OUT/run-true.txt"
mk=$(printf '%s\n' $rk | sort -n | sed -n 4p); ma=$(printf '%s\n' $ra | sort -n | sed -n 4p)
v "medians within 30% of each other (kContainerOS $mk ms, Alpine $ma ms; the machine was busy with other audits)" yes \
  "$([ $((mk * 10)) -lt $((ma * 13)) ] && [ $((ma * 10)) -lt $((mk * 13)) ] && echo yes || echo no)"
