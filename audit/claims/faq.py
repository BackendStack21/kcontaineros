#!/usr/bin/env python3
"""Compare the FAQPage JSON-LD of docs/index.html with the visible questions. Prints "same" or the differences."""
import html, json, re, sys
doc = open(sys.argv[1]).read()
faq = None
for m in re.finditer(r'<script type="application/ld\+json">(.*?)</script>', doc, re.S):
    j = json.loads(m.group(1))
    if j.get("@type") == "FAQPage": faq = j
text = lambda s: re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", s))).strip()
visible = [text(q) for q in re.findall(r"<summary><span>(.*?)</span></summary>", doc, re.S)]
ld = [re.sub(r"\s+", " ", q["name"]).strip() for q in faq["mainEntity"]]
if visible == ld: print("same")
else: print("visible-only: %s; json-only: %s" % ([q for q in visible if q not in ld], [q for q in ld if q not in visible]))
