"""Packages the extension for Chrome into dist/chrome/soft-subs-chrome and dist/SoftSubs-Chrome-<version>.zip.

It's the same code as the Safari extension; only the manifest differs. Usage: python scripts/build_chrome.py [version]
With --out DIR it writes the unpacked extension to DIR only, without the zip (the Mac app build bundles it this way).
"""

import json
import shutil
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = root / "Extension" / "Resources"
manifest = json.loads((source / "manifest.json").read_text(encoding="utf-8"))
args = sys.argv[1:]
out_dir = None
if "--out" in args:
    i = args.index("--out")
    out_dir = Path(args[i + 1])
    del args[i:i + 2]
version = args[0] if args else manifest["version"]

out = out_dir or root / "dist" / "chrome" / "soft-subs-chrome"
shutil.rmtree(out if out_dir else out.parent, ignore_errors=True)
out.mkdir(parents=True)
for file in source.iterdir():
    if file.suffix in (".js", ".html", ".css", ".png"):
        shutil.copy2(file, out / file.name)

manifest["version"] = version
manifest["minimum_chrome_version"] = "111"
# Chrome launches the helper through the softsubs:// link instead of Safari's native messaging.
manifest["permissions"] = [p for p in manifest["permissions"] if p != "nativeMessaging"]
# Safari tints the black toolbar glyphs; Chrome shows them as-is, so use the colored icon there.
manifest["action"]["default_icon"] = {"16": "icon-48.png", "32": "icon-48.png", "48": "icon-48.png"}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
if out_dir:
    sys.exit(0)

archive = shutil.make_archive(str(root / "dist" / f"SoftSubs-Chrome-{version}"), "zip", out.parent, out.name)
print(f"Packaged {Path(archive).relative_to(root)}")
