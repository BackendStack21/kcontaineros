#!/usr/bin/env python3
"""What is in the image: every entry of the layer (docker save) and of a
created container (docker export), with the checks a reviewer would make.

    python3 audit/supply/04-image-contents.py [IMAGE ...]   default: kcontaineros kcontaineros:sealed
"""
import io, os, posixpath, stat, sys, tarfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

images = sys.argv[1:] or ["kcontaineros", "kcontaineros:sealed"]
# what `docker create` adds to an exported filesystem (not part of the layer)
DOCKER_ADDS = {".dockerenv", "dev", "dev/console", "dev/pts", "dev/shm", "etc/hostname", "etc/hosts",
               "etc/mtab", "etc/resolv.conf", "proc", "sys"}
bad = 0
for image in images:
    print("=" * 20, image)
    cfg, layers = saved_image(image)
    print("config:", {k: cfg["config"].get(k) for k in ("User", "Env", "Entrypoint", "Cmd", "WorkingDir", "Volumes", "ExposedPorts", "Labels")})
    print("layers:", len(layers), "history:", [h.get("created_by") for h in cfg["history"]])
    lst = listing(layers[0])
    for p in sorted(lst):
        print("  " + fmt_entry(p, lst[p]))
    flags = []
    for p, e in sorted(lst.items()):
        if e["mode"] & 0o6000: flags.append("setuid/setgid: " + p)
        if e["mode"] & 0o002 and e["kind"] != "sym": flags.append("world-writable%s: %s" % (" (sticky)" if e["mode"] & 0o1000 else " NOT STICKY", p))
        if e["mode"] & 0o222 and e["kind"] in ("file", "dir") and not e["mode"] & 0o002: flags.append("writable by owner/group: %s %04o" % (p, e["mode"]))
        if e["kind"] in ("chr", "blk", "fifo", "other", "hard"): flags.append("special entry %s: %s" % (e["kind"], p))
        if e["uid"] or e["gid"] or e["uname"] not in ("", "root") : flags.append("not root-owned: %s %d:%d %s" % (p, e["uid"], e["gid"], e["uname"]))
        if e["mtime"] != 0: flags.append("mtime not 0: %s %d" % (p, e["mtime"]))
        if e["pax"]: flags.append("pax headers (xattrs?): %s %s" % (p, e["pax"]))
        if e["kind"] == "sym":
            tgt = posixpath.normpath(posixpath.join("/", posixpath.dirname(p), e["link"]))
            t = tgt.lstrip("/")
            if e["link"].startswith("/"): flags.append("absolute symlink: %s -> %s" % (p, e["link"]))
            if t not in lst: flags.append("symlink target not in image: %s -> %s (%s)" % (p, e["link"], tgt))
        if e["kind"] == "file" and e["mode"] & 0o111 and p not in ("bin/kcontaineros", "sbin/init"):
            flags.append("unexpected executable: " + p)
    print("flags (%d):" % len(flags))
    for f in flags: print("  ! " + f)
    files = [p for p, e in lst.items() if e["kind"] == "file"]
    print("regular files (%d): %s" % (len(files), sorted(files)))
    for p in sorted(files):
        if p.startswith("etc/"):
            print("--- /%s (%d bytes)" % (p, lst[p]["size"]))
            for n, line in enumerate(file_from(layers[0], p).split(b"\n")):
                print("   %2d| %r" % (n + 1, line.decode("latin1")))
    # passwd sanity
    pw = file_from(layers[0], "etc/passwd").decode().strip().split("\n")
    for line in pw:
        f = line.split(":")
        home, shell = f[5].lstrip("/") or ".", f[6].lstrip("/")
        print("passwd %-7s uid=%s home=%s (%s) shell=%s (%s)" % (f[0], f[2], f[5], "exists" if home in lst or home == "." else "MISSING", f[6],
              "exists" if shell in lst else "MISSING"))
    # the exported container: what docker adds on top
    name = "kcos-audit-supply-export-%d" % os.getpid()
    sh(["docker", "create", "--platform", PLATFORM, "--name", name, image, "x"])
    try:
        exp = listing(sh(["docker", "export", name]).stdout)
    finally:
        sh(["docker", "rm", "-f", name])
    extra = sorted(set(exp) - set(lst)); missing = sorted(set(lst) - set(exp))
    changed = [p for p in sorted(set(exp) & set(lst)) if {k: v for k, v in exp[p].items() if k != "pax"} != {k: v for k, v in lst[p].items() if k != "pax"}]
    print("docker export: %d entries; added by docker: %s" % (len(exp), extra))
    print("  unexpected additions:", [p for p in extra if p not in DOCKER_ADDS], " missing:", missing)
    for p in changed:
        print("  differs from layer: " + fmt_entry(p, exp[p]))
