#!/usr/bin/env python3
"""Reproducibility: compare the two from-scratch builds with each other, with
the prepared release image and with the binary embedded in docs/index.html.

    python3 audit/supply/02-compare.py [IMAGE_A IMAGE_B RELEASE]

Reads images with `docker save` (the layer as built, without the files a
container adds). Prints PASS/DIFF lines; exit status 1 if anything differs.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

a, b, rel = (sys.argv[1:4] + ["kcos-audit-supply-a", "kcos-audit-supply-b", "kcontaineros"][len(sys.argv) - 1:])[:3]
bad = 0


def report(ok, what, detail=""):
    global bad
    info = "informational" in what
    bad += 0 if ok or info else 1
    print("%s  %s%s" % ("PASS" if ok else "INFO-DIFF" if info else "DIFF", what, (": " + detail) if detail else ""))


imgs = {}
for name in (a, b, rel):
    cfg, layers = saved_image(name)
    insp = json.loads(sh(["docker", "image", "inspect", name]).stdout)[0]
    imgs[name] = dict(cfg=cfg, layers=layers, insp=insp)
    print("image %-22s id=%s layers=%d diff_ids=%s created=%s" % (
        name, insp["Id"][7:19], len(layers), [d[7:19] for d in cfg["rootfs"]["diff_ids"]], cfg.get("created")))

for x, y in ((a, b), (a, rel)):
    X, Y = imgs[x], imgs[y]
    report(X["cfg"]["rootfs"]["diff_ids"] == Y["cfg"]["rootfs"]["diff_ids"], "layer diff_ids %s == %s" % (x, y),
           "%s vs %s" % (X["cfg"]["rootfs"]["diff_ids"], Y["cfg"]["rootfs"]["diff_ids"]))
    report([sha(l) for l in X["layers"]] == [sha(l) for l in Y["layers"]], "layer tar bytes %s == %s" % (x, y))
    lx, ly = listing(X["layers"][0]), listing(Y["layers"][0])
    diffs = [p for p in sorted(set(lx) | set(ly)) if lx.get(p) != ly.get(p)]
    report(not diffs, "file list, modes, owners, timestamps, contents %s == %s (%d entries)" % (x, y, len(lx)),
           "; ".join(diffs[:10]))
    bx, by = file_from(X["layers"][0], "bin/kcontaineros"), file_from(Y["layers"][0], "bin/kcontaineros")
    report(bx == by, "/bin/kcontaineros %s == %s" % (x, y), "%s (%d) vs %s (%d)" % (sha(bx)[:16], len(bx), sha(by)[:16], len(by)))
    cx = {k: v for k, v in X["cfg"]["config"].items()}
    cy = {k: v for k, v in Y["cfg"]["config"].items()}
    report(cx == cy, "image config (Env, User, Entrypoint, Cmd) %s == %s" % (x, y), "%s vs %s" % (cx, cy))
    report(X["insp"]["Id"] == Y["insp"]["Id"], "image ID %s == %s (informational: includes build timestamps/attestation)" % (x, y),
           "%s vs %s" % (X["insp"]["Id"][7:19], Y["insp"]["Id"][7:19]))
    report(X["cfg"].get("created") == Y["cfg"].get("created"), "config 'created' %s == %s (informational)" % (x, y),
           "%s vs %s" % (X["cfg"].get("created"), Y["cfg"].get("created")))

emb = embedded_binary()
ba = file_from(imgs[a]["layers"][0], "bin/kcontaineros")
br = file_from(imgs[rel]["layers"][0], "bin/kcontaineros")
print("binary: build-a %d bytes sha256=%s" % (len(ba), sha(ba)))
print("binary: release %d bytes sha256=%s" % (len(br), sha(br)))
print("binary: docs    %d bytes sha256=%s" % (len(emb), sha(emb)))
report(emb == ba, "binary embedded in docs/index.html == fresh build")
report(emb == br, "binary embedded in docs/index.html == prepared release image")
report(len(ba) < 100000, "binary under 100 kB (README, AGENTS.md)", str(len(ba)))
report(round(len(ba) / 1000) == 90, "README 'one 90 kB Rust binary'", "%d bytes" % len(ba))
layer = imgs[a]["layers"][0]
content = sum(e["size"] for e in listing(layer).values())
print("layer: tar %d bytes, file contents %d bytes" % (len(layer), content))
size = sh(["docker", "images", "--format", "{{.Size}}", a]).stdout.decode().strip()
report(size == "239kB", "README 'Image size (docker images) 239 kB'", size)
hist = sh(["docker", "history", "--format", "{{.Size}}\t{{.CreatedBy}}", a]).stdout.decode()
first = [l for l in hist.splitlines() if "COPY" in l]
report(bool(first) and first[0].split("\t")[0] == "180kB", "README 'Root filesystem layer 180 kB' (docker history)", first[0] if first else hist)
print("history created-at values (reproducible builds would pin these):")
print(sh(["docker", "history", "--format", "  {{.CreatedAt}}  {{.Size}}  {{.CreatedBy}}", "--no-trunc", a]).stdout.decode().rstrip())
sys.exit(1 if bad else 0)
