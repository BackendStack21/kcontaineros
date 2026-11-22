#!/usr/bin/env python3
"""Write to stdout the binary embedded in docs/index.html (between the kcos-binary markers)."""
import base64, re, sys
doc = open(sys.argv[1]).read()
m = re.search(r"<!-- kcos-binary:begin[^\n]*-->\n(.*?)\n<!-- kcos-binary:end -->", doc, re.S)
inner = re.sub(r"<[^>]+>", "", m.group(1))
sys.stdout.buffer.write(base64.b64decode(re.sub(r"\s+", "", inner)))
