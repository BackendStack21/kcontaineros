"""Shared helpers for the supply-chain audit harness (python3 stdlib only)."""
import base64, hashlib, io, json, os, re, stat, subprocess, sys, tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PLATFORM = "linux/arm64"


def sh(args, timeout=120, check=True, **kw):
    r = subprocess.run(["timeout", str(timeout)] + args, capture_output=True, **kw)
    if check and r.returncode:
        sys.exit("command failed (%d): %s\n%s" % (r.returncode, " ".join(args), r.stderr.decode(errors="replace")))
    return r


def sha(b):
    return hashlib.sha256(b).hexdigest()


def saved_image(image):
    """docker save IMAGE -> (config dict, [layer bytes (uncompressed tar)], manifest digest list)."""
    data = sh(["docker", "save", image]).stdout
    tf = tarfile.open(fileobj=io.BytesIO(data))
    files = {m.name: m for m in tf.getmembers()}
    read = lambda n: tf.extractfile(files[n]).read()
    man = json.loads(read("manifest.json"))[0]
    config = json.loads(read(man["Config"]))
    layers = []
    for l in man["Layers"]:
        b = read(l)
        if b[:2] == b"\x1f\x8b":
            import gzip
            b = gzip.decompress(b)
        layers.append(b)
    return config, layers


def listing(layer_bytes):
    """Every entry of a tar as a dict keyed by path."""
    out = {}
    tf = tarfile.open(fileobj=io.BytesIO(layer_bytes))
    for m in tf.getmembers():
        kind = ("dir" if m.isdir() else "sym" if m.issym() else "hard" if m.islnk() else
                "file" if m.isfile() else "chr" if m.ischr() else "blk" if m.isblk() else
                "fifo" if m.isfifo() else "other")
        e = dict(kind=kind, mode=m.mode, uid=m.uid, gid=m.gid, uname=m.uname, gname=m.gname,
                 mtime=m.mtime, size=m.size, link=m.linkname, pax=dict(m.pax_headers))
        if m.isfile():
            e["sha256"] = sha(tf.extractfile(m).read())
        out[m.name.rstrip("/") or "."] = e
    return out


def file_from(layer_bytes, path):
    tf = tarfile.open(fileobj=io.BytesIO(layer_bytes))
    return tf.extractfile(tf.getmember(path)).read()


def embedded_binary(page=None):
    page = page or os.path.join(ROOT, "docs", "index.html")
    doc = open(page, encoding="utf-8").read()
    m = re.search(r'<!-- kcos-binary:begin[^\n]*-->\n<script type="application/octet-stream" id="kcos-binary">'
                  r'([A-Za-z0-9+/=\s]*)</script>\n<!-- kcos-binary:end -->', doc)
    if not m:
        sys.exit("no kcos-binary block in " + page)
    return base64.b64decode(m.group(1))


def fmt_entry(p, e):
    s = "%-5s %04o %5d:%-5d mtime=%-10d size=%-6d %s" % (e["kind"], e["mode"], e["uid"], e["gid"], e["mtime"], e["size"], p)
    if e["link"]:
        s += " -> " + e["link"]
    if "sha256" in e:
        s += "  sha256=" + e["sha256"][:16]
    return s
