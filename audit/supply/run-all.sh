#!/bin/sh
# Rerun the whole supply-chain audit. From the repo root:
#   sh audit/supply/run-all.sh            builds twice with --no-cache (minutes), fetches the live site
#   SKIP_BUILD=1 sh audit/supply/run-all.sh   reuse kcos-audit-supply-a/-b if they exist
#   KEEP=1 ...                            leave the kcos-audit-supply-* images in place afterwards
# Needs: docker (arm64 host), python3, curl, git, GNU timeout, and the images
# kcontaineros and kcontaineros:sealed (make build; docker build --target sealed).
# Output of each step is also written to audit/supply/out/.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
mkdir -p "$here/out"
step() { echo; echo "################ $1"; shift; "$@" 2>&1 | tee "$here/out/$(basename "$2" | sed 's/\.[a-z]*$//').txt"; }
step "01 build twice"            sh "$here/01-build-twice.sh"
step "02 compare"                python3 "$here/02-compare.py"
step "03 inputs"                 sh "$here/03-inputs.sh"
step "04 image contents"         python3 "$here/04-image-contents.py"
step "05 repo hygiene"           sh "$here/05-repo-hygiene.sh"
step "06 example"                sh "$here/06-example.sh"
step "07 site"                   python3 "$here/07-site.py" --live
step "08 repro variants"         sh "$here/08-repro-variants.sh"
step "09 maintainer scripts"     bash "$here/09-maintainer-scripts.sh"
if [ "${KEEP:-}" != 1 ]; then
  docker rmi -f kcos-audit-supply-a kcos-audit-supply-b kcos-audit-supply-toolchain kcos-audit-supply-http >/dev/null 2>&1
fi
echo; echo "left behind: $(docker ps -a --filter name=kcos-audit-supply --format '{{.Names}}' | tr '\n' ' ') $(docker images --format '{{.Repository}}' | grep '^kcos-audit-supply' | tr '\n' ' ')"
