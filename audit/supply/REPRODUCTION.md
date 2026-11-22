# Independent reproduction of track "supply" (S1-S8)

Run on 2026-11-22 against the working tree at deffcb4. Everything created in
Docker was named `kcos-audit-vsupply-*` and removed; the throwaway clone
lived in the session scratchpad and was deleted.

| id | verdict | severity |
|----|---------|----------|
| S1 | reproduced | low |
| S2 | reproduced (one sub-claim refuted: the suite does notice) | low |
| S3 | reproduced | info |
| S4 | reproduced | info |
| S5 | reproduced | info |
| S6 | reproduced | info |
| S7 | reproduced | info |
| S8 | not_reproduced | info |

## S1 - site-deploy guard ignores untracked/ignored files: reproduced, low

In a throwaway clone:

```
$ git diff --quiet HEAD -- docs/ && echo 'clean: guard passes'
clean: guard passes
$ echo 'TOKEN=example' > docs/notes.txt; printf x > docs/.DS_Store
$ git diff --quiet HEAD -- docs/ && echo 'untracked+ignored: guard passes'
untracked+ignored: guard passes
$ git status --porcelain --ignored -- docs/
?? docs/notes.txt
!! docs/.DS_Store
$ echo y >> docs/robots.txt; git diff --quiet HEAD -- docs/ || echo refuses
refuses
$ ls docs/.assetsignore
ls: docs/.assetsignore: No such file or directory
```

Only the guard half was observed; what wrangler uploads was not (no
credentials). Live `/.DS_Store` returns 404. README.md:600 words the guard
narrowly and accurately ("refuses to publish a page that the script had to
change"); AGENTS.md:173 ("refuses to deploy while docs/ differs from the
last commit") is the over-broad sentence. The normal deploy path (push to
main, Cloudflare builds from git) is not affected.

## S2 - untracked files under rootfs/ are shipped: reproduced, low

mkrootfs.sh alone, pinned toolchain image, `--network none`, repo read-only:

```
rc=0
./bin/kcontaineros ./etc/.env ./etc/.passwd.swp ./etc/group ./etc/nsswitch.conf
./etc/os-release ./etc/passwd ./etc/passwd~ ./stray.txt     (.DS_Store removed)
-r--r--r-- 1 root root 9 Jan 1 1970 .env
```

Full `docker build` of a clone with `rootfs/etc/.env`, `rootfs/etc/passwd~`,
`rootfs/.DS_Store` added:

```
$ docker export $c | tar -t | grep ^etc
etc etc/.env etc/group etc/hostname etc/hosts etc/mtab etc/nsswitch.conf etc/os-release etc/passwd etc/passwd~ etc/resolv.conf
$ docker run --rm kcos-audit-vsupply-s2img cat /etc/.env
SECRET=1
```

Correction to the auditor: the statement "the suite ... would not notice" is
wrong. test/suite.sh:15-17 ("the image contains exactly these files") and
:220-222 (sealed) compare the exported listing with a fixed list, in which
`etc/.env` and `etc/passwd~` do not appear, so `make test` fails. The gap is
only `make build` / `docker build` followed by a push without the suite.

## S3 - unpinned `npx wrangler`: reproduced, info

```
$ grep -n 'npx wrangler' Makefile
16:	npx wrangler dev
23:	npx wrangler deploy
$ ls package.json package-lock.json
ls: package-lock.json: No such file or directory
ls: package.json: No such file or directory
```

## S4 - build not hermetic / pin mismatch goes to the network: reproduced, info

```
$ docker run --rm --network none rust@sha256:8d0e82ab... sh -c 'rustup target list --installed; rustup target add aarch64-unknown-none'
aarch64-unknown-linux-musl
error: component download failed for rust-std-aarch64-unknown-none: ... could not download file from
'https://static.rust-lang.org/dist/2026-11-12/rust-std-1.100.0-aarch64-unknown-none.tar.xz' to
'/usr/local/rustup/downloads/340bd5041d83...c269.partial'
rc=1
$ (same image, sources copied, channel = "1.99.0") cargo build --release --locked
info: syncing channel updates for 1.99.0-aarch64-unknown-linux-musl
error: could not download file from 'https://static.rust-lang.org/dist/channel-rust-1.99.0.toml.sha256'
rc=1
```

README.md:114-116 ("compiler image pinned by digest, the toolchain by
version") is accurate as worded. I did not re-verify the "checksum passed"
line with network, only that the download target is named by the hash.

## S5 - .pyc with a local path in history: reproduced, info

```
$ git log --all --oneline --name-status -- 'test/__pycache__/*' docs/CNAME
8b6ca40 D test/__pycache__/pty.cpython-315.pyc
933889f D docs/CNAME
68681f6 A docs/CNAME, A test/__pycache__/pty.cpython-315.pyc
$ git show 68681f6:test/__pycache__/pty.cpython-315.pyc | strings | grep -c /Users/
1
$ git tag --contains 68681f6
v0.2.0
```

## S6 - e2e.sh cleanup matches by name pattern: reproduced, info

```
created (docker create, never started): kcos-audit-vsupply-ms-4242, -4242-x, -bench-4242, -other-14242
$ ID=4242; docker ps -a --format '{{.Names}}' --filter "name=^/kcos-.*-$ID\$"
kcos-audit-vsupply-ms-bench-4242
kcos-audit-vsupply-ms-4242
```

Needs a foreign container whose name starts with `kcos-` and ends in the
suite's PID; AGENTS.md documents the `kcos-...-$$` naming. On a shared
daemon (like this audit) it is a real, if small, collision risk.

## S7 - CSP 'unsafe-inline', font CSS without integrity: reproduced, info

```
$ grep -n -o '<script[^>]*>' docs/index.html
31, 49: application/ld+json   828: application/octet-stream   831: <script>
$ grep -n -E 'innerHTML|outerHTML|document\.write|eval\(|insertAdjacentHTML|location\.' docs/index.html
867: try { t = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1))); } catch (e) {}
$ curl -sI https://kcos.21no.de/
strict-transport-security: max-age=31536000
content-security-policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https://assets.21no.de; ...
```

No injection path; `location.hash` only feeds `getElementById`. The fonts
origin is documented (README.md:595-596).

## S8 - VM clock at 2001-01-01: not_reproduced, info

```
$ date -u; docker info --format '{{.SystemTime}}'
Sun 22 Nov 2026 09:31:01 UTC
2026-11-22T09:31:02.236479793Z
```

Clock correct during this review (container mtime output and TLS to
kcos.21no.de also fine). Transient environmental state caused by another
track; not a finding against the image and not verifiable after the fact.
