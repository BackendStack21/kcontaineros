#!/bin/bash
# Builds the helper binaries and the three images this track uses.
# Run from the repo root: audit/escape-user/build.sh
set -eu
cd "$(dirname "$0")"
T=kcos-audit-escape-user
mkdir -p out
# The compiler image the project itself builds with: it is already on this
# machine and carries gcc, musl and binutils (nothing has to be installed).
CC_IMAGE=${CC_IMAGE:-rust:1-alpine}
# 1. static helpers, compiled in a throwaway container
timeout 600 docker run --rm --platform linux/arm64 --name $T-build \
  -v "$PWD/helper:/src:ro" -v "$PWD/out:/out" "$CC_IMAGE" sh -c '
    gcc -static -O1 -o /out/kp /src/kp.c &&
    gcc -static -O1 -o /out/evil /src/evil.c &&
    gcc -c -o /tmp/p.o /src/payload.S && objcopy -O binary -j .text /tmp/p.o /out/payload.bin &&
    ls -l /out'
# 2. the audit image plus the helper (in /bb, a program directory) and the
#    payloads as data in /opt (not a program directory)
cat > out/Dockerfile.img <<'D'
FROM kcos-audit
COPY kp /bb/kp
COPY evil payload.bin /opt/
ENV PATH=/bb:/usr/local/bin:/usr/bin:/bin:/sbin
D
timeout 300 docker build -q --platform linux/arm64 -t $T-img -f out/Dockerfile.img out
# 3. what a third party would build: FROM kcontaineros + app + KCOS_EXEC,
#    default user nobody, a data directory, the app owned by nobody
rm -rf out/applets && mkdir out/applets
for a in $(timeout 60 docker run --rm --platform linux/arm64 --entrypoint /bb/busybox kcos-audit --list); do ln -s busybox out/applets/$a; done
cat > out/Dockerfile.third <<'D'
FROM kcos-audit AS tools
FROM kcontaineros
COPY --chown=65534:65534 kp /app/bin/kp
COPY --from=tools --chown=65534:65534 /bb/busybox /app/bin/busybox
COPY --chown=65534:65534 applets/ /app/bin/
COPY evil payload.bin /opt/
ENV KCOS_EXEC=/app/bin PATH=/app/bin:/usr/local/bin:/usr/bin:/bin:/sbin
WORKDIR /data
CMD ["/app/bin/kp"]
D
timeout 300 docker build -q --platform linux/arm64 -t $T-third -f out/Dockerfile.third out
# 4. the sealed image with a tool server stand-in (busybox + kp in /bb,
#    named by KCOS_EXEC), to run under the README's agent recipe
cat > out/Dockerfile.sealed <<'D'
FROM kcos-audit AS tools
FROM kcontaineros:sealed
COPY --from=tools /bb/ /bb/
COPY kp /bb/kp
ENV KCOS_EXEC=/bb PATH=/bb:/usr/local/bin:/usr/bin
COPY evil payload.bin /opt/
CMD ["kp"]
D
timeout 300 docker build -q --platform linux/arm64 -t $T-sealed -f out/Dockerfile.sealed out
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep "^$T-"
