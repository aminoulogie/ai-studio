"""Write the web update manifest for the bundled page. Used by GitHub Actions and Codemagic alike.
Usage: python3 ios/scripts/write_manifest.py VERSION
VERSION is the repository's commit count, so both builders number releases the same way and it only grows.
"""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
version = int(sys.argv[1])
page = (ROOT / 'ios/www/index.html').read_bytes()
observer = (ROOT / 'ios/AIStudio/claude-observer.js').read_bytes()
manifest = {
    'version': version,
    'sha256': hashlib.sha256(page).hexdigest(),
    'size': len(page),
    'min_native': 3,
    'observer_sha256': hashlib.sha256(observer).hexdigest(),
    'observer_size': len(observer),
}
text = json.dumps(manifest, indent=2)
(ROOT / 'ios/www/studio-web.json').write_text(text)
(ROOT / 'ios/studio-web.json').write_text(text)
(ROOT / 'ios/studio-web.html').write_bytes(page)
(ROOT / 'ios/studio-observer.js').write_bytes(observer)
print(text)
