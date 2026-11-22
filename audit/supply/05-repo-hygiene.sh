#!/bin/sh
# Repository hygiene: secrets in tree and history, files that should not be
# tracked, ignore-file gaps. Read-only. Run from the repo root.
set -u
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
KEYS='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|AIza[0-9A-Za-z_-]{35}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|CLOUDFLARE_API|CF_API|api[_-]?(key|token)|secret|passw(or)?d *[=:]|bearer [A-Za-z0-9]|account_id|zone_id|npm_[A-Za-z0-9]{36}|dckr_pat_'
echo "== commits: $(git rev-list --all | wc -l | tr -d ' ')   refs: $(git for-each-ref | wc -l | tr -d ' ')   stashes: $(git stash list | wc -l | tr -d ' ')"
git log --all --format='%h %an <%ae> %ad %s' --date=short
echo "== tracked files: $(git ls-files | wc -l | tr -d ' ')"
echo "== every path that ever existed in history, not present now"
git log --all --name-only --format= | sort -u > /tmp/kcos-audit-supply-hist.$$ ; git ls-files | sort > /tmp/kcos-audit-supply-now.$$
comm -23 /tmp/kcos-audit-supply-hist.$$ /tmp/kcos-audit-supply-now.$$; rm -f /tmp/kcos-audit-supply-hist.$$ /tmp/kcos-audit-supply-now.$$
echo "== key shapes in the tracked tree (base64 blob in docs/index.html excluded by line length)"
git grep -nIiE "$KEYS" -- . | awk 'length($0) < 400' | cut -c1-220
echo "== key shapes in added lines of the whole history (git log -p --all)"
git log -p --all --format='commit %h' | awk 'length($0) < 400' | grep -E '^(commit |\+)' | grep -iE "^commit |$KEYS" | awk '/^commit /{c=$0; next} {print c ": " substr($0,1,200)}' | sort -u
echo "== key shapes inside the embedded binary and the built binary (strings)"
python3 - <<'PY'
import base64, re, sys
doc = open("docs/index.html", encoding="utf-8").read()
b = base64.b64decode(re.search(r'id="kcos-binary">([A-Za-z0-9+/=\s]*)</script>', doc).group(1))
strs = re.findall(rb"[\x20-\x7e]{6,}", b)
hits = [s for s in strs if re.search(rb"(?i)/Users/|/home/|/root/\.cargo|/rustc/|/src/|\.rs\b|password|secret|token|BEGIN|@[a-z0-9-]+\.[a-z]{2,}", s)]
print("printable strings >=6: %d; path/secret-looking: %d" % (len(strs), len(hits)))
for s in hits[:20]: print("   ", s[:160].decode())
PY
echo "== large or binary tracked files"
git ls-files -z | xargs -0 ls -l | awk '$5 > 100000 {print $5, $9}'
git ls-files | while read -r f; do if ! grep -Iq . "$f" 2>/dev/null; then echo "binary: $f"; fi; done
echo "== PNG metadata chunks in docs/og.png (tEXt/iTXt/eXIf can carry author, software, GPS)"
python3 - <<'PY'
import struct
d = open("docs/og.png", "rb").read(); at = 8; kinds = []
while at < len(d):
    n, k = struct.unpack(">I4s", d[at:at+8]); kinds.append((k.decode(), n)); at += 12 + n
print(kinds)
PY
echo "== untracked and ignored files present in the working tree (candidates for leaking into a build context or a wrangler upload)"
git status --porcelain --ignored | grep -v '^?? audit/' | head -40
echo "== docs/: files on disk vs tracked (wrangler uploads the directory, not the git tree)"
ls -A docs | sort > /tmp/kcos-audit-supply-d1.$$; git ls-files docs | sed 's|^docs/||' | sort > /tmp/kcos-audit-supply-d2.$$
diff /tmp/kcos-audit-supply-d1.$$ /tmp/kcos-audit-supply-d2.$$ && echo "identical"; rm -f /tmp/kcos-audit-supply-d1.$$ /tmp/kcos-audit-supply-d2.$$
echo "== build context: what .dockerignore lets through (top level entries not ignored)"
for e in $(ls -A); do
  case "$e" in target|.git|examples|test|docs|.wrangler|node_modules|wrangler.jsonc|.DS_Store|__pycache__) ;; *) printf '%s ' "$e";; esac
done; echo
echo "   Dockerfile COPY sources:"; grep -n '^COPY' Dockerfile
echo "   names .gitignore has that .dockerignore lacks:"; for p in '.dev.vars*' '*.pyc' '.env'; do grep -qF "$p" .dockerignore || echo "     $p"; done
echo "== .gitignore does not cover: "; for p in .env '*.pem' '*.key' audit/; do grep -qF "$p" .gitignore || echo "     $p"; done
echo "== file modes of tracked scripts"; git ls-files -s tools test/e2e.sh test/term.py test/elf.py | awk '{print $1, $4}'
echo "== symlinks tracked"; git ls-files -s | awk '$1==120000'
echo "== CI configuration"; ls -d .github .gitlab-ci.yml .circleci 2>/dev/null || echo "none in the repository (README: 'A push to main deploys it' is configured on the Cloudflare side)"
echo "== git remotes"; git remote -v | sed 's|//[^@/]*@|//<credentials-redacted>@|'
echo "== git config: credentials embedded in URLs?"; git config --local --list | grep -iE 'url|token|password|extraheader' | sed 's|//[^@/]*@|//<credentials-redacted>@|' || true
