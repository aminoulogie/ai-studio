"""Embed the CDN library and the Studio assets into ios/www/index.html so the app loads no code from the internet."""
import re
import sys
import urllib.request
from pathlib import Path

CDN = "https://cdnjs.cloudflare.com/ajax/libs/"
path = sys.argv[1]
root = Path(__file__).resolve().parents[2]
html = Path(path).read_text(encoding="utf-8")


def fetch(rel):
    with urllib.request.urlopen(CDN + rel, timeout=60) as r:
        return r.read().decode("utf-8").replace("</script", "<\\/script")


for rel in ["highlight.js/11.9.0/highlight.min.js"]:
    tag = f'<script src="{CDN}{rel}"></script>'
    assert tag in html, tag
    html = html.replace(tag, "<script>" + fetch(rel) + "</script>")
assert not re.search(r'<script src="https://', html)

# Our own scripts and styles, inlined on the same HTTPS origin the app always uses.
for asset in ["assets/repo-privacy.js", "assets/agents.js", "assets/github.js", "assets/usage.js"]:
    tag = f'<script src="{asset}"></script>'
    assert tag in html, tag
    html = html.replace(tag, "<script>" + (root / asset).read_text(encoding="utf-8").replace("</script", "<\\/script") + "</script>")
tag = '<link rel="stylesheet" href="assets/studio.css">'
assert tag in html, tag
html = html.replace(tag, "<style>" + (root / "assets/studio.css").read_text(encoding="utf-8") + "</style>")
Path(path).write_text(html, encoding="utf-8")
print("inlined libraries and assets,", len(html) // 1024, "KB")
