#!/bin/bash
# Builds the helper image kcos-audit-init-img: kcos-audit plus /bb/kh (the
# static helper kh.c) and a few files in /bb for the exec-failure cases.
# Run from the repo root. Remove with: docker rmi kcos-audit-init-img
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
cp "$here/kh.c" "$ctx/"
# The project's pinned Rust image already has gcc and musl-dev, and is in
# the local cache; a fresh "apk add gcc" needs disk the daemon may not have.
RUST=$(sed -n 's/^FROM .* \(rust:[^ ]*\) AS toolchain$/\1/p' "$here/../../Dockerfile")
cat > "$ctx/Dockerfile" <<EOF
FROM $RUST AS build
COPY kh.c /kh.c
RUN gcc -static -O1 -o /kh /kh.c
# Files for the exec failures. All of them end up in /bb, a program directory.
RUN mkdir /x && cd /x \
 && printf 'echo not a program\n' > noexec && chmod 644 noexec \
 && head -c 4096 /dev/urandom > garbage && chmod 755 garbage \
 && : > empty && chmod 755 empty \
 && printf '#!/nonexistent/interp\n' > badinterp && chmod 755 badinterp \
 && printf '#!/bb/busybox sh\necho script ran \$#\n' > script && chmod 755 script \
 && printf 'echo no shebang\n' > noshebang && chmod 755 noshebang \
 && printf '#!/bb/busybox %s\n' xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx > bigscript && chmod 755 bigscript \\
 && ln -s loop loop && ln -s nowhere dangling && mkdir adir \
 && ln -s /bb/kh 'x) S 1 1 1 (' \
 && cp /kh kh \
 && mkdir locked p1 && cp /kh locked/khx && chmod 000 locked \
 && printf 'x' > p1/true && chmod 644 p1/true \
 && printf 'echo text' > p1/echo && chmod 755 p1/echo

FROM kcos-audit
COPY --from=build /x/ /bb/
EOF
timeout 600 docker build --platform linux/arm64 -q -t kcos-audit-init-img "$ctx"
# The sealed image with the helper as its only program.
cat > "$ctx/Dockerfile.sealed" <<EOF
FROM kcontaineros:sealed
COPY --from=kcos-audit-init-img /bb/kh /usr/local/bin/kh
EOF
timeout 600 docker build --platform linux/arm64 -q -t kcos-audit-init-sealed -f "$ctx/Dockerfile.sealed" "$ctx"
