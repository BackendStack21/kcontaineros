# Sizes, contents and build properties of the images.
echo "== image, sizes, binary"
tmp=$(mktemp -d)
docker rm -f kcos-audit-claims-ex >/dev/null 2>&1
docker create "${P[@]}" --name kcos-audit-claims-ex "$IMG" >/dev/null
docker cp -q kcos-audit-claims-ex:/bin/kcontaineros "$tmp/kc.bin"
docker export kcos-audit-claims-ex | tar -tv > "$tmp/listing"
docker rm kcos-audit-claims-ex >/dev/null
BIN=$tmp/kc.bin
size=$(wc -c < "$BIN" | tr -d ' ')

claim R001 "R/I: the whole userland is one static binary of under 100 kB"
v "binary is under 100000 bytes (measured: $size)" yes "$([ "$size" -lt 100000 ] && echo yes || echo no)"
claim R002 "R (Compared with Alpine): one 90 kB Rust binary"
v "wc -c of /bin/kcontaineros, rounded to kB" 90 "$(( (size + 500) / 1000 ))"
claim R003 "R: no libc, static: the binary has no interpreter and no dynamic dependencies"
v "ELF: static PIE, no PT_INTERP, no DT_NEEDED, GNU_STACK not executable, no W+X segment, RELRO" \
  "type=ET_DYN interp=no needed=0 execstack=no wx=no relro=yes" "$(python3 $HERE/elfcheck.py "$BIN")"
claim R004 "R: the Docker image is under 250 kB"
isize=$(docker image inspect -f '{{.Size}}' "$IMG")
v "docker image inspect size under 250000 (measured: $isize)" yes "$([ "$isize" -lt 250000 ] && echo yes || echo no)"
claim R005 "R (Compared with Alpine): image size (docker images) 239 kB"
v "docker images size column" 239kB "$(docker images --format '{{.Size}}' "$IMG:latest")"
claim R006 "R (Compared with Alpine): root filesystem layer 180 kB"
v "docker history, the COPY /rootfs layer" 180kB "$(docker history --format '{{.Size}} {{.CreatedBy}}' "$IMG" | awk '/COPY/{print $1}')"
claim R007 "R/I: the image contains nothing else except four small files in /etc (plus directories and links)"
v "regular files in the exported image, without what Docker adds" "bin/kcontaineros etc/group etc/nsswitch.conf etc/os-release etc/passwd " \
  "$(awk '$1 ~ /^-/{print $NF}' "$tmp/listing" | grep -v -E '^(\.dockerenv|dev/console|etc/(hostname|hosts|resolv\.conf))$' | LC_ALL=C sort | tr '\n' ' ')"
claim R008 "R/I: all utilities, sh and init are symlinks to /bin/kcontaineros, and so is /usr/bin/env; I: plus a /var/run link"
v "symbolic links in the image" \
  "bin/cat bin/chmod bin/chown bin/cp bin/echo bin/env bin/false bin/kill bin/ln bin/ls bin/mkdir bin/mv bin/ps bin/pwd bin/rm bin/sh bin/sleep bin/touch bin/true bin/uname sbin/init usr/bin/env var/run " \
  "$(awk '$1 ~ /^l/' "$tmp/listing" | sed 's/ -> .*//' | awk '{print $NF}' | grep -v '^etc/mtab$' | LC_ALL=C sort | tr '\n' ' ')"
t "every link under /bin, /sbin and /usr resolves to the one binary" 0 "22 same" -- \
  R --entrypoint /bb/busybox "$A" sh -c 'B=/bb/busybox; n=0; for l in /bin/* /sbin/init /usr/bin/env; do [ -L $l ] && [ "$($B readlink -f $l)" = /bin/kcontaineros ] && n=$((n+1)); done; echo "$n same"'
claim R009 "R: /bin/* is cat chmod chown cp echo env false kill ln ls mkdir mv ps pwd rm sleep touch true uname; (Alpine table) 19 utilities, plus sh and init"
t "kcontaineros --list" 0 "init sh cat chmod chown cp echo env false kill ln ls mkdir mv ps pwd rm sleep touch true uname " -- \
  R --entrypoint /bb/busybox "$A" sh -c '/bin/kcontaineros --list | /bb/busybox tr "\n" " "'
v "number of utilities" 19 "$(R --entrypoint /bin/kcontaineros "$IMG" --list | grep -v -c -x -E 'init|sh')"
claim R010 "R: the image runs as nobody; ENTRYPOINT is /sbin/init, CMD /bin/sh; R/L: linux/arm64"
v "image configuration" "65534:65534 [/sbin/init] [/bin/sh] linux/arm64" "$(docker image inspect -f '{{.Config.User}} {{.Config.Entrypoint}} {{.Config.Cmd}} {{.Os}}/{{.Architecture}}' "$IMG")"
v "uid and gid of the command" "65534 65534" "$(R "$IMG" cat /proc/self/status | awk '$1=="Uid:"||$1=="Gid:"{printf "%s ", $2}' | sed 's/ $//')"
claim R011 "R: kcontaineros:sealed is init and nothing else: about 100 kB, no shell, no utilities, no writable directory"
ssize=$(docker image inspect -f '{{.Size}}' "$SEALED")
v "sealed image size within 10% of 100 kB (measured: $ssize)" yes "$([ "$ssize" -gt 90000 ] && [ "$ssize" -lt 110000 ] && echo yes || echo no)"
docker create "${P[@]}" --name kcos-audit-claims-ex "$SEALED" x >/dev/null
docker export kcos-audit-claims-ex | tar -tv > "$tmp/sealed-listing"
docker cp -q kcos-audit-claims-ex:/sbin/init "$tmp/sealed.bin" 2>/dev/null || docker cp -q -L kcos-audit-claims-ex:/sbin/init "$tmp/sealed.bin"
docker rm kcos-audit-claims-ex >/dev/null
v "files and links in the sealed image, without what Docker adds" "etc/group etc/nsswitch.conf etc/os-release etc/passwd sbin/init var/run " \
  "$(awk '$1 !~ /^d/' "$tmp/sealed-listing" | sed 's/ -> .*//' | awk '{print $NF}' | grep -v -E '^(\.dockerenv|dev/console|etc/(hostname|hosts|resolv\.conf|mtab))$' | LC_ALL=C sort | tr '\n' ' ')"
v "directories writable by owner, group or other in the sealed image (from the tar listing; Docker's /dev entries aside)" "" \
  "$(awk '$1 ~ /^d/ && $1 ~ /w/ {print $NF}' "$tmp/sealed-listing" | grep -v '^dev/' | tr '\n' ' ')"
claim R012 "R/I: the sealed binary is built without the shell and utility code, so there is none to reach by renaming it"
v "strings of the shell and utilities in the sealed binary (syntax error, applet not found, usage: chmod)" "0" \
  "$(LC_ALL=C grep -a -c -E 'syntax error|applet not found|usage: chmod' "$tmp/sealed.bin")"
v "the same strings in the full binary (control)" "yes" "$([ "$(LC_ALL=C grep -a -c -E 'syntax error|applet not found|usage: chmod' "$BIN")" -gt 0 ] && echo yes)"
claim R013 "I: \$ docker run --rm kcontaineros:sealed sh -> kcontaineros: sh: no such file or directory (terminal session on the page)"
t "the session, character for character" 127 "kcontaineros: sh: no such file or directory" -- R "$SEALED" sh
claim R014 "R: Pinned: the compiler image is pinned by digest, the toolchain by version"
v "Dockerfile FROM lines carrying a sha256 digest / FROM lines naming an external image" "1/1" \
  "$(grep -c -E '^FROM .*@sha256:[0-9a-f]{64}' Dockerfile)/$(grep -E '^FROM ' Dockerfile | grep -v -E 'FROM (scratch|toolchain)' | wc -l | tr -d ' ')"
v "rust-toolchain.toml names an exact version" yes "$(grep -q -E '^channel = "[0-9]+\.[0-9]+\.[0-9]+"' rust-toolchain.toml && echo yes || echo no)"
claim R015 "R: No dependencies: no crates"
v "[dependencies] entries in Cargo.toml / packages in Cargo.lock" "0/1" "$(awk '/^\[dependencies\]/{f=1;next} /^\[/{f=0} f&&NF' Cargo.toml | wc -l | tr -d ' ')/$(grep -c '^\[\[package\]\]' Cargo.lock)"
claim R016 "R: unwind tables of the prebuilt core library are still in the binary; no stack protector or BTI/PAC"
v "the binary has an .eh_frame section and no BTI/PAC note" "eh_frame=yes bti=no" "$(python3 $HERE/elfcheck.py --notes "$BIN")"
claim R017 "I: the binary embedded in docs/index.html is the image's binary"
v "sha256 of the embedded copy against the image's /bin/kcontaineros" "$(shasum -a 256 < "$BIN" | cut -d' ' -f1)" "$(python3 $HERE/embedded.py docs/index.html | shasum -a 256 | cut -d' ' -f1)"
claim R018 "AGENTS/I: the FAQ structured data is derived from the visible questions"
v "questions in JSON-LD against the visible <h3>/<summary> questions" same "$(python3 $HERE/faq.py docs/index.html)"
claim R019 "R: version: kContainerOS 0.2.0; os-release carries it"
t "--version" 0 "kcontaineros 0.2.0" -- R "$IMG" kcontaineros --version
v "VERSION_ID in /etc/os-release" "VERSION_ID=0.2.0" "$(R "$IMG" cat /etc/os-release | grep '^VERSION_ID=')"
rm -rf "$tmp"
