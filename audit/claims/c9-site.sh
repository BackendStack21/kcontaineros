# What the README says about docs/ and the derived parts of the page; an entry of /dev the documents do not list.
echo "== site and leftovers"
claim D001 "R: the page makes no request outside its own origin except for the fonts on assets.21no.de"
v "hosts in src= and stylesheet/preconnect links of docs/index.html, and in url() of its styles" "assets.21no.de " \
  "$(python3 - docs/index.html <<'PY'
import re, sys
d = open(sys.argv[1]).read()
hosts = set()
for tag in re.findall(r"<(?:script|img|link|iframe|source|video|audio)\b[^>]*>", d):
    if tag.startswith("<link") and not re.search(r'rel="(stylesheet|preconnect|preload|icon|dns-prefetch)', tag): continue
    for u in re.findall(r'(?:src|href)="(https?://[^"]+)"', tag): hosts.add(u.split("/")[2])
for u in re.findall(r"url\((https?://[^)]+)\)", d): hosts.add(u.split("/")[2])
for u in re.findall(r"(?:fetch|XMLHttpRequest|sendBeacon)\(", d): hosts.add("script-request")
print(" ".join(sorted(hosts)) + " ")
PY
)"
v "the Content-Security-Policy of docs/_headers allows no other origin" "https://assets.21no.de" "$(grep 'Content-Security-Policy' docs/_headers | grep -o -E 'https?://[^ ;]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
claim D002 "R: unknown paths get docs/404.html with status 404"
v "wrangler.jsonc: assets.not_found_handling, and the file exists" "404-page yes" "$(sed -n 's/.*"not_found_handling": "\(.*\)".*/\1/p' wrangler.jsonc) $([ -s docs/404.html ] && echo yes || echo no)"
claim D003 "AGENTS/R: tools/update-docs.sh regenerates what is derived (embedded binary, FAQ structured data, og.png); run on the image as built, it changes nothing"
tmp=$(mktemp -d); rsync -a --exclude target --exclude audit --exclude .git ./ "$tmp/"
( cd "$tmp" && timeout 300 tools/update-docs.sh kcontaineros ) > "$OUT/update-docs.log" 2>&1; rc=$?
v "tools/update-docs.sh on a copy of the checkout: status, and files of docs/ that differ afterwards" "0 changed:" "$rc changed:$(diff -rq docs "$tmp/docs" | awk '{printf " %s", $2}')"
rm -rf "$tmp"
claim D004 "R (Layout): the files and directories the README lists exist"
v "missing" "" "$(for f in src/sys.rs src/lock.rs src/init.rs src/sh.rs src/applets.rs src/util.rs src/main.rs tools/mkrootfs.sh test/e2e.sh test/suite.sh test/cases test/term.py test/elf.py test/probe.rs docs/index.html docs/404.html docs/og.png docs/_headers docs/robots.txt docs/sitemap.xml docs/llms.txt wrangler.jsonc AGENTS.md tools/update-docs.sh tools/update-og.py examples/hello-http LICENSE; do [ -e "$f" ] || printf '%s ' "$f"; done)"
claim D005 "R/I/L: of /dev ... nothing else: an unnamed device is not opened, whatever its name (src/lock.rs also allows /dev/termination-log, which no document lists)"
t "a device mapped to /dev/termination-log, not named in KCOS_DEV, as nobody" 0 $'read=1\nwrite=1' -- \
  R "${NOBODY[@]}" --device /dev/zero:/dev/termination-log "$A" /bb/busybox sh -c '(true < /dev/termination-log) 2>/dev/null; echo "read=$?"; (true >> /dev/termination-log) 2>/dev/null; echo "write=$?"'
claim D006 "L: llms.txt: the utilities, the lockdown list and the limits agree with the README (compared by hand; the utility list by machine)"
v "utility list of llms.txt against kcontaineros --list" "$(R --entrypoint /bin/kcontaineros "$IMG" --list | grep -v -x -E 'init|sh' | tr '\n' ' ' | sed 's/ $//')" "$(sed -n 's/^- Utilities: \(.*\)\.$/\1/p' docs/llms.txt)"
v "utility list of the README's first table and of the page" "same same" \
  "$([ "$(sed -n 's/^| `\/bin\/\*` | `\(.*\)` |$/\1/p' README.md)" = "$(sed -n 's/^- Utilities: \(.*\)\.$/\1/p' docs/llms.txt)" ] && echo same || echo differ) $(grep -q "$(sed -n 's/^- Utilities: \(.*\)\.$/\1/p' docs/llms.txt)" docs/index.html && echo same || echo differ)"
