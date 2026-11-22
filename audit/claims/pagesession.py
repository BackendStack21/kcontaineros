#!/usr/bin/env python3
"""Print the text of the Nth terminal session (<pre> under a "Terminal" tag) of docs/index.html, tags removed."""
import html, re, sys
doc = open(sys.argv[1]).read()
pres = re.findall(r'<span class="tag">Terminal</span></div>\s*<pre[^>]*>(.*?)</pre>', doc, re.S)
print(html.unescape(re.sub(r"<[^>]+>", "", pres[int(sys.argv[2])])))
