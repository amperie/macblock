"""Build deterministic signed-manifest input; the Swift signer owns key handling."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

root, version, sequence, base = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]
suffix = sys.argv[5] if len(sys.argv) > 5 else ''
if suffix and not re.fullmatch(r'-[0-9]+-[0-9]+', suffix):
    raise SystemExit('Invalid artifact suffix')
parts = urlsplit(base)
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not 0 < sequence < 2**53:
    raise SystemExit('Invalid version/sequence')
if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
    raise SystemExit('Public HTTPS release URL required')
artifacts = {}
for name, filename in [('agent', 'orbit-agent'), ('monitor', 'orbit-foreground')]:
    data = (root / 'update-binaries' / filename).read_bytes()
    if not 0 < len(data) <= 20_000_000:
        raise SystemExit('Invalid artifact size')
    artifacts[name] = dict(url=base.rstrip('/') + '/' + filename + suffix,
                           sha256=hashlib.sha256(data).hexdigest(), size=len(data))
(root / 'update.json').write_text(json.dumps(dict(schemaVersion=1, sequence=sequence,
    version=version, artifacts=artifacts), sort_keys=True, separators=(',', ':')))
