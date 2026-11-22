# Track: supply

What the auditor of this track reported, unedited apart from layout, and what the
independent reviewer made of each finding. The state of the tree is that of 0.2.0
(commit `deffcb4`); what was done about each finding is in [../README.md](../README.md).

## What was exercised

Track supply (build, artefacts, site, examples) for kContainerOS 0.2.0 at deffcb4. No critical, high or medium findings; 2 low, 6 info.

DELIVERABLE NOT WRITTEN: audit/supply/REPORT.md. The Write tool refused it ("Subagents should return findings as text, not write report files") and I did not work around that guard; the report's content is in this result instead. The harness and its saved output are in place.

Exercised (counts):
- 2 sequential `docker build --no-cache` (kcos-audit-supply-a, -b); 1 fully cached build of the `toolchain` stage to get an offline image; 6 further compilations in throwaway containers (release + sealed feature sets; another directory; umask 077 with disturbed source modes/mtimes; all without network; and one under the amd64 variant of the pinned compiler image, emulated).
- 3 images (a, b, prepared `kcontaineros`) compared pairwise via `docker save`: 16 comparisons passed, 4 informational differences (image ID, `created`).
- 44 entries of the full layer and 17 of the sealed layer listed and checked (setuid/setgid, world-writable, owner-writable, special files, ownership, mtime, xattrs, symlink targets, unexpected executables); /etc printed line by line; 2 `docker export` listings.
- 4 commits, 1 tag, 59 tracked files, 2 history-only paths; key-shape grep over tree and `git log -p --all`; 90 printable strings of the binary; PNG chunks of og.png.
- examples/hello-http: 1 build, 3 runs (default, README hardened flags, bad PORT), 1 build on the sealed base (expected failure).
- Site: static analysis of index.html/404.html against docs/_headers; 21 read-only GETs to kcos.21no.de (19 HTTPS paths, 1 HTTP, 1 header repeat).
- Maintainer scripts in a throwaway clone: tools/update-docs.sh 5 runs (2 normal, missing image, sealed image, SIGINT); deploy guard in 4 tree states; e2e.sh cleanup filter against 4 container names; SIGINT against 2 scripts; stray files in rootfs/ through mkrootfs.sh.

Key numbers: single layer diff_id sha256:454a193f5d715c26639237b370b2313f6f49027ec6f4459cd0ca006e90762192 in all three images; /bin/kcontaineros 90,240 bytes sha256 dc0f304000df6acaf402aeb223edd1531330c63ba9503d1ac9bfa8ab641efd60 everywhere (both builds, release image, docs/index.html, live page, 4 variant builds); sealed init 19,160 bytes sha256 1240e2d6... equals kcontaineros:sealed. docker images 239kB, docker history 180kB, sealed 101kB, layer tar 116,224 bytes.

Environment note for the orchestrator (not a product finding, see S8): the shared Docker VM clock read 2001-01-01T00:00:2xZ at 09:24:56Z and 2001-01-01T00:00:17Z at 09:27:18Z host time, correct in between and after. I ran nothing privileged. It broke one of my registry pulls (TLS "certificate is not yet valid").

Left on the machine: all kcos-audit-supply-* images and containers removed. The amd64 variant of the pinned rust image (same digest reference) was pulled by 08-repro-variants.sh and remains in the image store. Nothing outside audit/supply/ was written in the repo; nothing committed.

Rerun: `sh audit/supply/run-all.sh` from the repo root (SKIP_BUILD=1 reuses the two builds, KEEP=1 keeps images). Saved output of this run: audit/supply/out/.

## What held

- README 'a rebuild from scratch produces the identical image layer': two --no-cache builds and the prepared release image have byte-identical layer tars (diff_id sha256:454a193f...2192), identical 44 entries with mode, 0:0 ownership, mtime 0, link targets and contents
- The binary is byte-identical (90,240 bytes, sha256 dc0f3040...fd60) when built in another directory, with umask 077 and disturbed source modes/mtimes, and by the amd64 variant of the pinned compiler image (what FROM --platform=$BUILDPLATFORM selects on an x86 host); the rootfs listing hash was identical in all four variants
- The binary embedded in docs/index.html equals the fresh builds, the release image and the copy served live at https://kcos.21no.de/
- Sealed /sbin/init (19,160 bytes) in kcontaineros:sealed equals an offline compile with --no-default-features
- README sizes match what Docker reports: 239 kB image, 180 kB layer (docker history), 90 kB binary, sealed about 100 kB (101kB), binary under 100 kB, image under 250 kB
- Every external base image is pinned by digest (Dockerfile, examples/hello-http/Dockerfile, busybox in test/e2e.sh); rust-toolchain.toml 1.100.0 matches the image's rustc 1.100.0
- Every cargo build uses --locked; zero dependencies confirmed by Cargo.toml, Cargo.lock (1 package), cargo metadata --offline --locked (1 package, no edges), cargo tree, no build.rs, only `extern crate alloc`
- cargo build fetches nothing: it ran to the same hash with --network none; the one download of the build (rust-std for aarch64-unknown-none) is checked by rustup against sha256 340bd504...c269, which is in the channel manifest inside the digest-pinned image
- Full image contents: 5 regular files (bin/kcontaineros 0555 plus four 0444 files in /etc), 21 relative symlinks all resolving inside the image, no setuid/setgid, no device nodes, no hard links, no xattrs, nothing owner-writable, everything root-owned, only /tmp and /var/tmp world-writable (sticky), /root 0500; config user 65534:65534, entrypoint /sbin/init
- Sealed image: 17 entries, one executable, no writable directory, passwd shells set to /sbin/nologin
- /etc/passwd, group, os-release (VERSION_ID=0.2.0), nsswitch.conf contain only what rootfs/ and mkrootfs.sh say; docker export adds only Docker's own files
- No secret, token or key shape in the tree or in any of the 4 commits; no host paths in the binary; no metadata chunks in docs/og.png; no tracked symlinks or stray binaries
- tools/update-docs.sh regenerates docs/ byte-identical to the commit from the release image, is idempotent, exits 1 without touching docs/ for a missing image or the sealed image, and on SIGINT exits 130 leaving no container and docs/ intact
- test/e2e.sh structure on SIGINT: bash dies of the signal and the EXIT trap (cleanup) runs
- Live site: /, /llms.txt, /robots.txt, /sitemap.xml, /og.png byte-identical to the repo; all 19 responses including 404s carry every header from docs/_headers; unknown paths return 404 with docs/404.html and do not reflect the path; /_headers, /wrangler.jsonc, /.git/HEAD, /.DS_Store, /README.md, /CNAME are 404; HTTP redirects to HTTPS
- The pages stay within the CSP: one inline script (index only), one <style> each, no style= attributes, no on*= handlers, no forms/frames/base, only foreign load is the font stylesheet on assets.21no.de
- No DOM injection path: no innerHTML/document.write/eval/string timers; section names from the embedded binary reach the DOM only via textContent, Element.append(string) and title; the only URL input is location.hash passed to getElementById
- FAQ structured data, visible questions and README questions agree (11 each); utilities list identical in README, page and llms.txt; the page's limits list matches the README's; llms.txt is shorter but contradicts nothing
- examples/hello-http follows the README's advice (static binary in /usr/local/bin, exec-form CMD, USER 0 only around RUN, back to 65534:65534), builds, runs under /sbin/init as 65534 with CapEff 0 / NoNewPrivs 1 / Seccomp 2, answers, stops in 177-184 ms with exit 143, also under --read-only --cap-drop ALL --security-opt no-new-privileges --memory 64m --pids-limit 128 --ipc none; fails at RUN on the sealed base as documented
- ELF properties of the shipped binary per test/elf.py: type=pie interp=no execstack=no wx=no relro=yes

## Not tested

- audit/supply/REPORT.md was not written: the Write tool refused report files for this subagent and I did not bypass it; its content is carried in this result
- What `npx wrangler deploy` actually uploads from docs/ (needs the maintainer's Cloudflare credentials); only the guard in front of it was exercised
- The Cloudflare side of 'a push to main deploys it' (build configuration, who can trigger it, any workers.dev hostname): not visible from the repository
- https://assets.21no.de/fonts/fonts.css and what it loads: outside the hosts this audit was allowed to contact
- The page in a real browser (CSP violation reports, rendering, clipboard): source and served bytes were analysed, no browser was driven
- `make test` and `make coverage` as a whole: they rebuild the shared `kcontaineros` tag and this track was limited to two rebuilds; the suite's own reproducibility and amd64-refusal checks were therefore not run
- Sealed and coverage targets were not rebuilt with --no-cache; the sealed binary was compared through an offline compile, the coverage image not at all
- Reproducibility on another machine, another Docker/BuildKit version or a later date; both --no-cache builds ran on the same daemon within the same minute
- A native x86 build host: the amd64 compiler image ran under emulation
- The published GitHub repository and any registry image: only the local clone and local images were examined
- User-facing behaviour of test/term.py and tools/update-og.py on hostile input (they only process the maintainer's own files)
- The SIGINT behaviour of the real test/e2e.sh mid-suite: observed on a script with the same trap structure, not on the suite itself

## Findings

### S1 — site-deploy guard does not see untracked or ignored files in docs/

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: Makefile:20-23 (site-deploy), wrangler.jsonc assets.directory

The Makefile guards `npx wrangler deploy` with `git diff --quiet HEAD -- docs/`. AGENTS.md says it 'refuses to deploy while docs/ differs from the last commit'. `git diff` ignores untracked files, and .gitignore'd ones such as .DS_Store, so the guard passes with extra files present in docs/, the directory wrangler.jsonc names as assets.directory. There is no docs/.assetsignore. Observed: the guard half only. What wrangler then uploads was not observed (no credentials); the live site currently returns 404 for /.DS_Store.

Reproduction:

```
bash audit/supply/09-maintainer-scripts.sh   # section B
# or by hand, in a throwaway clone:
git clone -q . /tmp/x && cd /tmp/x
echo 'TOKEN=example' > docs/notes.txt; printf x > docs/.DS_Store
git diff --quiet HEAD -- docs/ && echo 'guard passes'
ls -A docs
```

Expected: The guard refuses when docs/ on disk is not exactly the committed docs/.

Observed: clean tree: guard passes; tracked file modified: guard refuses; UNTRACKED file docs/notes.txt: guard passes (deploy would go ahead); plus ignored file docs/.DS_Store: guard passes. Directory handed to wrangler: _headers .DS_Store 404.html index.html llms.txt notes.txt og.png robots.txt sitemap.xml

Reviewer: Only the guard half is observed; what wrangler uploads was not (no credentials). README.md:600 words the guard narrowly and accurately ('refuses to publish a page that the script had to change'); the over-broad sentence is AGENTS.md:173. The normal deploy path (push to main, built from git) is unaffected, so only the manual `make site-deploy` is exposed.

### S2 — Untracked files under rootfs/ are shipped in the image

- Severity: auditor **low**, reviewer **low**
- Reviewer's verdict: reproduced
- Where: Dockerfile:15, tools/mkrootfs.sh:14-16, .dockerignore

The Dockerfile does `COPY rootfs rootfs` and tools/mkrootfs.sh does `cp -R rootfs/.` into the image root. .dockerignore and mkrootfs.sh drop only .DS_Store. Any other untracked file a maintainer has there (editor backup of passwd, swap file, a .env) lands in /etc of the release image with mode 0444, silently breaking 'contains nothing else except four small files in /etc' and the reproducibility of the layer from a given commit. The suite compares a rebuild from the same working tree, so it would not notice.

Reproduction:

```
bash audit/supply/09-maintainer-scripts.sh   # section E: in the toolchain stage, --network none, repo mounted read-only, copies the sources, adds rootfs/etc/.env, rootfs/etc/passwd~, rootfs/etc/.passwd.swp, rootfs/.DS_Store, runs tools/mkrootfs.sh and lists the result
```

Expected: Only etc/group, etc/nsswitch.conf, etc/os-release, etc/passwd in the image, or a failed build.

Observed: etc/.env etc/.passwd.swp etc/group etc/nsswitch.conf etc/os-release etc/passwd etc/passwd~  (.DS_Store was removed, the rest shipped)

Reviewer: One sub-claim is refuted: the auditor says the suite would not notice. test/suite.sh:15-17 ('the image contains exactly these files') and :220-222 (sealed) compare the exported listing against a fixed literal list that has only etc/group, etc/nsswitch.conf, etc/os-release, etc/passwd, so `make test` would fail with stray files (I read the check, did not run the whole suite). The remaining gap is a `make build`/`docker build` and push without running the suite. Second suggested fix (compare against a fixed expectation) already exists.

### S3 — Deploy tool is unpinned: `npx wrangler` with no package.json or lockfile

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: Makefile:17,23

`make site-preview` and `make site-deploy` run `npx wrangler` without a version, and the repository has no package.json or lockfile (wrangler.jsonc's $schema points into a node_modules that is not described anywhere). Whatever version npm resolves at that moment runs with the maintainer's Cloudflare credentials. This contrasts with the digest pinning of the image build.

Reproduction:

```
grep -n 'npx wrangler' Makefile; ls package.json package-lock.json
```

Expected: A pinned wrangler version (devDependency with lockfile, or `npx wrangler@X.Y.Z`).

Observed: Makefile: 2 x 'npx wrangler' without a version; package.json: none; package-lock.json: none

Reviewer: Maintainer-side hygiene, not part of the shipped image. README documents the commands as `npx wrangler` literally, but says nothing about versions.

### S4 — Build is not hermetic; a toolchain pin mismatch would fetch an unpinned compiler

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: Dockerfile:10,26; rust-toolchain.toml

The README's wording ('compiler image pinned by digest, toolchain by version') is accurate, but two things follow that it does not say. (1) Every from-scratch build downloads rust-std for aarch64-unknown-none from static.rust-lang.org (`RUN rustup target add`); offline the step fails. The archive is hash-checked against the manifest inside the pinned image, so integrity holds; availability depends on that URL. libcore/liballoc/compiler_builtins in the shipped binary come from this download. (2) rust-toolchain.toml and the Dockerfile tag are two pins kept in step by hand; when the file names a version the image lacks, rustup goes to the network for that toolchain instead of failing, so the build would silently use a compiler not covered by the digest. The coverage stage additionally runs `apk add --no-cache musl-dev` without a version (never shipped).

Reproduction:

```
sh audit/supply/03-inputs.sh
# (1) docker run --rm --network none rust:1.100.0-alpine3.24@sha256:8d0e82ab... rustup target add aarch64-unknown-none
# (2) same image, --network none, sources copied, rust-toolchain.toml channel = "1.99.0", cargo build --release --locked
```

Expected: (1) informational. (2) A build that fails when the two pins disagree.

Observed: (1) error: component download failed for rust-std-aarch64-unknown-none ... could not download file from 'https://static.rust-lang.org/dist/2026-11-12/rust-std-1.100.0-aarch64-unknown-none.tar.xz'; with network: 'checksum passed', and the expected hash 340bd5041d83...c269 is at line 31935 of the image's multirust-channel-manifest.toml. (2) info: syncing channel updates for 1.99.0-aarch64-unknown-linux-musl / error: could not download file from 'https://static.rust-lang.org/dist/channel-rust-1.99.0.toml.sha256' (only the lack of network stopped it)

Reviewer: README.md:114-116 ('compiler image pinned by digest, the toolchain by version') is accurate as worded; integrity of rust-std is covered by the hash-named download from the manifest in the pinned image. I did not re-run the with-network 'checksum passed' step. Hardening suggestion, not a false claim.

### S5 — Git history contains a compiled .pyc with the maintainer's absolute checkout path

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: commit 68681f6: test/__pycache__/pty.cpython-315.pyc

test/__pycache__/pty.cpython-315.pyc was added in the first commit and deleted in 8b6ca40. It is still in history (and in the v0.2.0 tag's ancestry) and embeds the absolute path of the local checkout, including the local user name. No secret in it. docs/CNAME is the other history-only path (contains only the public hostname).

Reproduction:

```
git log --all --oneline --name-status -- 'test/__pycache__/*'
git show 68681f6:test/__pycache__/pty.cpython-315.pyc | strings | grep /Users/
```

Expected: No build artefacts or local paths in history.

Observed: A test/__pycache__/pty.cpython-315.pyc (68681f6), D (8b6ca40); strings shows the absolute path .../ligeros/test/pty.py under the maintainer's home directory

Reviewer: One absolute local path with the local user name, no secret. Harmless.

### S6 — test/e2e.sh cleanup removes any container named kcos-*-<PID>, and a default run retags `kcontaineros`

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: test/e2e.sh:34

cleanup() runs `docker ps -aq --filter "name=^/kcos-.*-$ID\$" | xargs -r docker rm -f` with ID=$$. Any container on the daemon whose name starts with kcos- and ends in -<that PID> is force-removed, whoever created it (for example another tool's kcos-foo-4242 while the suite runs as PID 4242). The match is anchored correctly otherwise. Separately, `make test` without IMG= rebuilds and retags `kcontaineros`, the same tag tools/update-docs.sh embeds into the site (documented in AGENTS.md via IMG=).

Reproduction:

```
bash audit/supply/09-maintainer-scripts.sh   # section C: creates 4 stopped containers and applies the filter with ID=4242
```

Expected: Only containers the run created are removed (e.g. matched by a label set at creation).

Observed: created: kcos-audit-supply-ms-4242 kcos-audit-supply-ms-4242-x kcos-audit-supply-ms-bench-4242 kcos-audit-supply-ms-other-14242; matched by e2e.sh's filter: kcos-audit-supply-ms-4242 kcos-audit-supply-ms-bench-4242

Reviewer: Requires a foreign container named kcos-*-<suite PID>; AGENTS.md documents the kcos-...-$$ naming and the IMG= override. Small but real collision risk on a shared daemon such as this audit's (many kcos-audit-* names exist).

### S7 — CSP relies on script-src 'unsafe-inline'; font stylesheet loaded cross-origin without integrity

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: reproduced
- Where: docs/_headers:4; docs/index.html:148,831

docs/_headers allows any inline script. The page has exactly one executable inline script and no injection path was found, so this is defence in depth only: if markup injection were ever introduced, the CSP would not stop script execution. The stylesheet https://assets.21no.de/fonts/fonts.css is loaded from another origin with no integrity attribute; img-src 'self' data: and font-src limit what that CSS could do. HSTS is max-age=31536000 without includeSubDomains. The README's statement that the page makes no request outside its origin except fonts on assets.21no.de matches the source.

Reproduction:

```
python3 audit/supply/07-site.py --live
```

Expected: Informational.

Observed: script-src 'unsafe-inline'; index.html: 4 <script> (2 ld+json, 1 octet-stream data block, 1 inline js), script src=: [], DOM/exec sinks: [], reads of attacker-controlled input: ['location.hash']; live headers identical to _headers on all 19 paths

Reviewer: Facts confirmed; no injection path exists, so defence in depth only. The fonts origin is documented in README.md:595-596. Not a vulnerability.

### S8 — Environment: the shared Docker VM clock was repeatedly at 2001-01-01 during the audit

- Severity: auditor **info**, reviewer **info**
- Reviewer's verdict: not reproduced
- Where: shared Docker Desktop VM (another run on the daemon)

Not a finding against the image from this track, reported because someone should chase it. `docker info --format '{{.SystemTime}}'` and `date -u` in a container showed 2001-01-01T00:00:2xZ at host time 09:24:56Z and 2001-01-01T00:00:17Z at 09:27:18Z; the clock was correct at ~09:25-09:26Z and at 09:27:54Z. So the VM clock is being set to 2001-01-01T00:00:00Z repeatedly and resynced in between. I started no privileged container and none with CAP_SYS_TIME. The README says clock changes are refused under init; whether these came from a control run without init (expected to succeed) or from a run under init is unknown to me. Effect on this track: one registry pull failed with 'x509: certificate has expired or is not yet valid: current time 2001-01-01T00:00:16Z', and rustup downloads failed silently in one harness run; both were repeated successfully.

Reproduction:

```
date -u; docker info --format '{{.SystemTime}}'; docker run --rm --entrypoint /bb/busybox kcos-audit date -u   # compare while other tracks are running
```

Expected: VM clock equal to host clock.

Observed: host: Sun 22 Nov 2026 09:24:56 UTC; container: Mon Jan 1 00:00:21 UTC 2001; docker info: 2001-01-01T00:00:22.219516968Z

Reviewer: Transient environment state attributed to another track's run, not a finding against the image; cannot be verified after the fact and I did not attempt to set the clock. Worth the orchestrator checking which track's no-init control changed the shared VM clock.

