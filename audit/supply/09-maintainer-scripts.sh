#!/bin/bash
# Scripts a maintainer runs: tools/update-docs.sh, the Makefile's deploy guard,
# test/e2e.sh's cleanup. Everything is exercised in a throwaway clone outside
# the repository; containers are named kcos-audit-supply-*. Run from the repo root.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/kcos-audit-supply.XXXXXX")
cleanup() {
  docker ps -aq --filter 'name=^/kcos-audit-supply-(ms|docs)-' | xargs -r docker rm -f >/dev/null 2>&1
  rm -rf "$tmp"
}
trap cleanup EXIT
git clone -q "$root" "$tmp/repo" && cd "$tmp/repo" || exit 1
echo "clone at $(git rev-parse --short HEAD)"

echo "== A. tools/update-docs.sh on the release image: does it reproduce the committed docs/, and is it idempotent?"
# only change in the copy: the container name, to keep to this audit's naming rule
sed -i.bak 's/^name=kcos-docs-extract-\$\$/name=kcos-audit-supply-docs-$$/' tools/update-docs.sh && rm tools/update-docs.sh.bak
timeout 120 tools/update-docs.sh kcontaineros; echo "rc=$?"
git status --porcelain -- docs | sed 's/^/   changed: /'; git diff --quiet HEAD -- docs && echo "   docs/ identical to the commit after regenerating"
timeout 120 tools/update-docs.sh kcontaineros; echo "rc=$? (second run)"
echo "   image argument that does not exist:"; out=$(timeout 60 tools/update-docs.sh kcos-audit-supply-no-such-image 2>&1); rc=$?; echo "$out" | tail -2; echo "   rc=$rc"
echo "   leftovers: containers=$(docker ps -aq --filter name=kcos-audit-supply-docs | wc -l | tr -d ' ') temp dirs=$(ls -d "${TMPDIR:-/tmp}"/tmp.* 2>/dev/null | wc -l | tr -d ' ') (pre-existing ones included)"
echo "   sealed image (no /bin/kcontaineros):"; out=$(timeout 60 tools/update-docs.sh kcontaineros:sealed 2>&1); rc=$?; echo "$out" | tail -2; echo "   rc=$rc"
git diff --quiet HEAD -- docs && echo "   docs/ still identical after the failed runs"
echo "   interrupted (SIGINT to the process group after 0.25 s):"
python3 - <<'PY'
import os, signal, subprocess, time
p = subprocess.Popen(["tools/update-docs.sh", "kcontaineros"], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
time.sleep(0.25); os.killpg(p.pid, signal.SIGINT)
out = p.communicate(timeout=60)[0].decode()
print("   rc=%d output=%r" % (p.returncode, out[-200:]))
PY
sleep 1
echo "   leftover containers: $(docker ps -a --filter name=kcos-audit-supply-docs --format '{{.Names}}' | tr '\n' ' ')"
git diff --quiet HEAD -- docs && echo "   docs/ identical after the interrupt" || { echo "   docs/ CHANGED by the interrupted run:"; git status --porcelain -- docs; git checkout -q -- docs; }

echo "== B. the Makefile's guard before 'npx wrangler deploy': git diff --quiet HEAD -- docs/"
guard() { git diff --quiet HEAD -- docs/ && echo "guard passes (deploy would go ahead)" || echo "guard refuses"; }
printf '   clean tree:                              '; guard
echo 'x' >> docs/llms.txt;            printf '   tracked file modified:                   '; guard; git checkout -q -- docs
echo 'TOKEN=example' > docs/notes.txt; printf '   UNTRACKED file docs/notes.txt:           '; guard
printf 'x' > docs/.DS_Store;          printf '   plus ignored file docs/.DS_Store:        '; guard
echo "   files wrangler would be pointed at (assets.directory ./docs): $(ls -A docs | tr '\n' ' ')"
echo "   .assetsignore present: $(ls docs/.assetsignore 2>/dev/null || echo no)"
rm -f docs/notes.txt docs/.DS_Store
echo "   wrangler pinned? package.json: $(ls package.json 2>/dev/null || echo none)  package-lock.json: $(ls package-lock.json 2>/dev/null || echo none)  Makefile: $(grep -c 'npx wrangler' Makefile) x 'npx wrangler' without a version"

echo "== C. test/e2e.sh cleanup: which container names does its filter remove for ID=4242?"
grep -n 'docker ps -aq --filter' test/e2e.sh
for n in kcos-audit-supply-ms-bench-4242 kcos-audit-supply-ms-other-14242 kcos-audit-supply-ms-4242 kcos-audit-supply-ms-4242-x; do
  timeout 60 docker create --platform linux/arm64 --name "$n" kcontaineros true >/dev/null
done
ID=4242
echo "   created: $(docker ps -a --filter name=kcos-audit-supply-ms --format '{{.Names}}' | sort | tr '\n' ' ')"
echo "   matched by e2e.sh's filter (would be removed with docker rm -f): $(docker ps -a --filter "name=^/kcos-.*-$ID\$" --format '{{.Names}}' | sort | tr '\n' ' ')"
docker ps -aq --filter 'name=^/kcos-audit-supply-ms-' | xargs -r docker rm -f >/dev/null

echo "== D. Ctrl-C while a check is running: e2e.sh traps EXIT only. Same structure, SIGINT to the foreground process group:"
cat > "$tmp/int.sh" <<'SH'
#!/usr/bin/env bash
set -u
cleanup() { echo "cleanup ran"; docker rm -f kcos-audit-supply-ms-int >/dev/null 2>&1; }
trap cleanup EXIT
out=$(docker run --rm --platform linux/arm64 --name kcos-audit-supply-ms-int kcontaineros sleep 20 2>&1 </dev/null); echo "check 1 returned rc=$? out=[$out]"
echo "the script went on to check 2 after the interrupt"
SH
python3 - "$tmp/int.sh" <<'PY'
import os, signal, subprocess, sys, time
p = subprocess.Popen(["bash", sys.argv[1]], start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
time.sleep(4); os.killpg(p.pid, signal.SIGINT)
try: out = p.communicate(timeout=60)[0].decode()
except subprocess.TimeoutExpired: p.kill(); out = "TIMEOUT"
print("   rc=%s\n   %s" % (p.returncode, out.strip().replace("\n", "\n   ")))
PY

echo "== E. what an untracked editor file in rootfs/ does to the image (COPY rootfs rootfs + cp -R in mkrootfs.sh; .dockerignore only drops .DS_Store)"
docker image inspect kcos-audit-supply-toolchain >/dev/null 2>&1 || \
  timeout 600 docker build -q --platform linux/arm64 --target toolchain -t kcos-audit-supply-toolchain "$root" >/dev/null
timeout 120 docker run --rm --platform linux/arm64 --network none -v "$root:/repo:ro" kcos-audit-supply-toolchain sh -c '
  mkdir /w && cd /repo && cp -r Cargo.toml rootfs tools src /w/ && cd /w
  echo "db_password=example" > rootfs/etc/.env; cp rootfs/etc/passwd "rootfs/etc/passwd~"; : > rootfs/etc/.passwd.swp; : > rootfs/.DS_Store
  printf "\177ELF" > /w/fake && tools/mkrootfs.sh /w/fake /out && cd /out && find etc -type f | sort | tr "\n" " "; echo; ls -A /out | tr "\n" " "; echo'
