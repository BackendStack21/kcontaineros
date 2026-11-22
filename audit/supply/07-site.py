#!/usr/bin/env python3
"""The site: docs/_headers against what the page does, DOM sinks, and (with
--live) the deployed site against the repository. Read-only GETs to
https://kcos.21no.de only.

    python3 audit/supply/07-site.py [--live]
"""
import hashlib, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import ROOT, embedded_binary, sha

docs = os.path.join(ROOT, "docs")
page = open(os.path.join(docs, "index.html"), encoding="utf-8").read()
nob64 = re.sub(r'(id="kcos-binary">)[A-Za-z0-9+/=\s]*(</script>)', r"\1\2", page)
p404 = open(os.path.join(docs, "404.html"), encoding="utf-8").read()
headers = open(os.path.join(docs, "_headers"), encoding="utf-8").read()
csp = re.search(r"Content-Security-Policy: (.*)", headers).group(1)
print("== CSP in docs/_headers")
for d in csp.split(";"): print("   " + d.strip())

print("== what the pages actually do")
for name, doc in (("index.html", nob64), ("404.html", p404)):
    scripts = re.findall(r"<script\b([^>]*)>", doc)
    print("%s: %d <script> (%s)" % (name, len(scripts), ", ".join(s.strip() or "inline js" for s in scripts)))
    print("   script src=: %s" % re.findall(r"<script[^>]*\bsrc=[\"']?([^\"' >]+)", doc))
    print("   <style> blocks: %d, style= attributes: %d, on*= handlers: %d" % (
        len(re.findall(r"<style\b", doc)), len(re.findall(r"\sstyle=", doc)), len(re.findall(r"\son[a-z]+=", doc))))
    origins = sorted(set(re.findall(r"""(?:src|href|action|content|url\()=?["'(]?(https?://[^/"' )>]+)""", doc)))
    print("   absolute origins mentioned: %s" % origins)
    loads = re.findall(r"<(?:link|img|script|iframe|source|video|audio|object|embed)\b[^>]*?(?:href|src)=[\"']([^\"']+)[\"'][^>]*>", doc)
    print("   resources loaded by tags: %s" % [l[:70] for l in loads])
    print("   @import / url( in CSS: %s" % [u[:60] for u in re.findall(r"@import[^;]+;|url\([^)]*\)", doc)])
    print("   <form>: %d  <iframe>: %d  <base>: %d  <meta http-equiv>: %s" % (
        len(re.findall(r"<form\b", doc)), len(re.findall(r"<iframe\b", doc)), len(re.findall(r"<base\b", doc)),
        re.findall(r"<meta[^>]*http-equiv[^>]*>", doc)))
    sinks = re.findall(r"innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function|setTimeout\(\s*[\"']|srcdoc|javascript:|\.href\s*=|location\s*=|location\.(assign|replace)", doc)
    print("   DOM/exec sinks: %s" % sinks)
    print("   reads of attacker-controlled input: %s" % sorted(set(re.findall(r"location\.\w+|document\.referrer|window\.name|URLSearchParams|postMessage|localStorage|document\.cookie", doc))))

print("== strings taken from the embedded binary that reach the DOM (section names)")
b = embedded_binary()
import struct
shoff, shentsize, shnum, shstrndx = struct.unpack_from("<Q", b, 40)[0], *struct.unpack_from("<HHH", b, 58)
strtab = struct.unpack_from("<Q", b, shoff + shstrndx * shentsize + 24)[0]
names = []
for k in range(shnum):
    o = strtab + struct.unpack_from("<I", b, shoff + k * shentsize)[0]
    names.append(b[o:b.index(b"\0", o)].decode("latin1"))
print("   %s" % names)
print("   reach the page through: textContent / Element.append(string) / li.title only (see the script; no markup sink)")

print("== consistency of generated parts")
m = re.search(r'<!-- kcos-faq:begin[^\n]*-->\n<script type="application/ld\+json">(.*?)</script>', page, re.S)
import json
faq = json.loads(m.group(1))
vis = re.findall(r"<summary>(.*?)</summary>", re.search(r'<section[^>]*\bid="questions".*?</section>', page, re.S).group(0), re.S)
print("   FAQ structured data: %d questions; visible <summary>: %d" % (len(faq["mainEntity"]), len(vis)))
readme = open(os.path.join(ROOT, "README.md"), encoding="utf-8").read()
rq = re.findall(r"^### (.*)$", readme[readme.index("## Common questions"):readme.index("## Supported features")], re.M)
print("   README common questions: %d" % len(rq))
llms = open(os.path.join(docs, "llms.txt"), encoding="utf-8").read()
ut = lambda s: re.search(r"`cat chmod[^`]*`|cat chmod [a-z ]*uname", s).group(0).strip("`")
print("   utilities list README == llms.txt == page: %s" % (ut(readme) == ut(llms), ))
for claim in ("0.2.0", "under 100 kB", "239 kB", "180 kB", "90 kB", "250 kB"):
    print("   %-14s README:%d page:%d llms:%d" % (claim, readme.count(claim), nob64.count(claim) + nob64.count(claim.replace(" ", "&nbsp;")) + nob64.count(claim.replace(" ", " ")), llms.count(claim)))

if "--live" not in sys.argv:
    sys.exit(0)

def get(path, extra=()):
    r = subprocess.run(["curl", "-sS", "--max-time", "20", "-A", "curl", "-D", "-", "-o", "/tmp/kcos-audit-supply-body.%d" % os.getpid(), *extra,
                        "https://kcos.21no.de" + path], capture_output=True)
    body = b""
    try:
        body = open("/tmp/kcos-audit-supply-body.%d" % os.getpid(), "rb").read(); os.unlink("/tmp/kcos-audit-supply-body.%d" % os.getpid())
    except OSError: pass
    head = r.stdout.decode("latin1").replace("\r", "")
    status = head.split("\n")[0]
    h = {}
    for line in head.split("\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1); h.setdefault(k.strip().lower(), v.strip())
    return status, h, body, r.stderr.decode()

print("== live: https://kcos.21no.de")
want = {}
for line in headers.split("/og.png")[0].splitlines():
    if line.startswith("  ") and ":" in line:
        k, v = line.strip().split(":", 1); want[k.lower()] = v.strip()
local = {"/": "index.html", "/index.html": "index.html", "/404.html": "404.html", "/llms.txt": "llms.txt", "/robots.txt": "robots.txt",
         "/sitemap.xml": "sitemap.xml", "/og.png": "og.png"}
for path in ["/", "/index.html", "/llms.txt", "/robots.txt", "/sitemap.xml", "/og.png", "/404.html", "/no-such-page", "/no/such/dir/",
             "/_headers", "/_redirects", "/wrangler.jsonc", "/.DS_Store", "/.git/HEAD", "/.assetsignore", "/README.md", "/CNAME",
             "/?x=%3Cscript%3Ealert(1)%3C/script%3E", "/%3Cscript%3Ealert(1)%3C/script%3E"]:
    status, h, body, err = get(path)
    same = ""
    if path in local:
        lb = open(os.path.join(docs, local[path]), "rb").read()
        same = "  body==repo:%s" % (body == lb) + ("" if body == lb else " (live %d bytes sha %s, repo %d bytes sha %s)" % (len(body), sha(body)[:12], len(lb), sha(lb)[:12]))
    miss = [k for k, v in want.items() if h.get(k) != v]
    print("%-45s %s  type=%s  len=%d%s" % (path, status, h.get("content-type"), len(body), same))
    print("    security headers missing or different from _headers: %s" % (miss or "none"))
    if path in ("/", "/no-such-page"):
        for k in sorted(h): print("      %s: %s" % (k, h[k][:300]))
    if path.startswith("/no-such") or "script" in path:
        print("    404 body is docs/404.html: %s; path reflected in body: %s" % (body == open(os.path.join(docs, "404.html"), "rb").read(), b"alert(1)" in body))
    if path == "/":
        lm = re.search(rb'id="kcos-binary">([A-Za-z0-9+/=\s]*)</script>', body)
        if lm:
            import base64
            lb2 = base64.b64decode(lm.group(1))
            print("    live embedded binary: %d bytes sha256=%s; repo embedded: %s; equal: %s" % (len(lb2), sha(lb2), sha(b), lb2 == b))
status, h, body, err = get("/", ["--http1.1"]); 
r = subprocess.run(["curl", "-sS", "--max-time", "20", "-A", "curl", "-o", "/dev/null", "-w", "%{http_code} -> %{redirect_url}", "http://kcos.21no.de/"], capture_output=True)
print("http://kcos.21no.de/ : %s %s" % (r.stdout.decode(), r.stderr.decode().strip()))
