#!/bin/sh
# Refresh the generated parts of the landing page, docs/index.html.
#
#   tools/update-docs.sh [IMAGE]        IMAGE defaults to kcontaineros
#
# 1. Copies /bin/kcontaineros out of a local image and writes it, base64
#    encoded, between the kcos-binary:begin and kcos-binary:end markers.
#    The page reads everything it shows about the binary (size, layout,
#    section names) from that copy.
# 2. Rewrites the FAQPage structured data between the kcos-faq:begin and
#    kcos-faq:end markers from the visible "Common questions" section, so
#    the two always say the same thing.
#
# Run it after every rebuild of the image and after editing the questions.
# Running it twice changes nothing. Needs docker and python3.
set -eu

image=${1:-kcontaineros}
here=$(cd "$(dirname "$0")/.." && pwd)
page=$here/docs/index.html
tmp=$(mktemp -d)
name=kcos-docs-extract-$$
created=

cleanup() {
    if [ -n "$created" ]; then docker rm -f "$name" >/dev/null 2>&1 || true; fi
    rm -rf "$tmp"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# --pull never: use the local image only, never a same-named one from a registry.
docker create --pull never --name "$name" "$image" >/dev/null
created=1
docker cp -L "$name:/bin/kcontaineros" "$tmp/kcontaineros" >/dev/null

python3 - "$page" "$tmp/kcontaineros" "$image" <<'EOF'
import base64, html, json, re, sys

page, binary, image = sys.argv[1:4]


def fail(msg):
    sys.exit("update-docs: " + msg)


def replace_block(doc, name, inner_re, new_inner):
    """Replace the one element between the NAME:begin and NAME:end markers."""
    pat = re.compile(r"(<!-- %s:begin[^\n]*-->\n)%s(\n<!-- %s:end -->)" % (name, inner_re, name), re.S)
    found = len(pat.findall(doc))
    if found != 1:
        fail("expected one %s block in %s, found %d" % (name, page, found))
    return pat.sub(lambda m: m.group(1) + new_inner + m.group(2), doc)


# ---- the binary
data = open(binary, "rb").read()
if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
    fail("%s:/bin/kcontaineros is not a 64-bit little-endian ELF file" % image)
if int.from_bytes(data[18:20], "little") != 0xB7:
    fail("%s:/bin/kcontaineros is not an AArch64 binary" % image)
# The headline and the meta description say "under 100 kB".
if len(data) >= 100000:
    fail("the binary is %d bytes; docs/index.html says it is under 100 kB. "
         "Change that wording first." % len(data))

old = open(page, encoding="utf-8").read()
doc = replace_block(
    old, "kcos-binary",
    r'<script type="application/octet-stream" id="kcos-binary">[A-Za-z0-9+/=\s]*</script>',
    '<script type="application/octet-stream" id="kcos-binary">%s</script>'
    % base64.b64encode(data).decode("ascii"))

# ---- the questions, as structured data
section = re.search(r'<section[^>]*\bid="questions".*?</section>', doc, re.S)
if not section:
    fail('no <section id="questions"> in %s' % page)


def text(fragment, keep_lines=False):
    t = html.unescape(re.sub(r"<[^>]+>", "", fragment))
    return t.strip("\n") if keep_lines else " ".join(t.split())


questions = []
for item in re.finditer(r"<details\b[^>]*>(.*?)</details>", section.group(0), re.S):
    q = re.search(r"<summary>(.*?)</summary>", item.group(1), re.S)
    a = re.search(r'<div class="a">(.*)</div>\s*$', item.group(1), re.S)
    if not q or not a:
        fail("a question in the Common questions section has no <summary> or answer")
    # The visible answer: paragraphs, list items and code, minus copy buttons.
    body = re.sub(r'<div class="code-head">.*?</div>', "", a.group(1), flags=re.S)
    parts = []
    for m in re.finditer(r"<(p|li|pre)\b[^>]*>(.*?)</\1>", body, re.S):
        parts.append(text(m.group(2), keep_lines=m.group(1) == "pre"))
    questions.append({
        "@type": "Question",
        "name": text(q.group(1)),
        "acceptedAnswer": {"@type": "Answer", "text": "\n".join(parts)},
    })
if not questions:
    fail("no questions found in the Common questions section")

faq = {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": questions}
faq_json = json.dumps(faq, ensure_ascii=False, indent=2).replace("<", "\\u003c")
doc = replace_block(doc, "kcos-faq", r'<script type="application/ld\+json">.*?</script>',
                    '<script type="application/ld+json">\n%s\n</script>' % faq_json)

if doc == old:
    print("docs/index.html is up to date (binary: %d bytes from %s; %d questions)"
          % (len(data), image, len(questions)))
else:
    with open(page, "w", encoding="utf-8", newline="") as f:
        f.write(doc)
    print("docs/index.html updated (binary: %d bytes from %s; %d questions)"
          % (len(data), image, len(questions)))
EOF
