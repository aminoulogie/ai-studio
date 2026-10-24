"""Embed the CDN libraries into ios/www/index.html so the app loads no code from the internet."""
import re
import sys
import urllib.request

CDN = "https://cdnjs.cloudflare.com/ajax/libs/"
path = sys.argv[1]
html = open(path, encoding="utf-8").read()


def fetch(rel):
    with urllib.request.urlopen(CDN + rel, timeout=60) as r:
        return r.read().decode("utf-8").replace("</script", "<\\/script")


for rel in ["highlight.js/11.9.0/highlight.min.js", "pdf.js/3.11.174/pdf.min.js"]:
    tag = f'<script src="{CDN}{rel}"></script>'
    assert tag in html, tag
    html = html.replace(tag, "<script>" + fetch(rel) + "</script>")

worker = fetch("pdf.js/3.11.174/pdf.worker.min.js")
html = html.replace("<script>", f'<script id="pdfWorker" type="text/plain">{worker}</script>\n<script>', 1)
assert not re.search(r'<script src="https://cdnjs', html)
open(path, "w", encoding="utf-8").write(html)
print("inlined libraries,", len(html) // 1024, "KB")


# Bundle our UI and request code while retaining the same HTTPS origin for existing logins.
from pathlib import Path
root = Path(__file__).resolve().parents[2]
html = Path(path).read_text(encoding="utf-8")
for asset in ["assets/repo-privacy.js", "assets/code-runtime.js", "assets/studio.js"]:
    tag = f'<script src="{asset}"></script>'
    assert tag in html, tag
    html = html.replace(tag, "<script>" + (root / asset).read_text().replace("</script", "<\\/script") + "</script>")
tag = '<link rel="stylesheet" href="assets/studio.css">'
assert tag in html
html = html.replace(tag, "<style>" + (root / "assets/studio.css").read_text() + "</style>")
Path(path).write_text(html, encoding="utf-8")
