#!/bin/bash
# resolved-sync.sh — fail when the Xcode workspace lockfile disagrees with the
# SwiftPM root lockfile. xcodebuild (CI test/release legs) reads the WORKSPACE
# copy; swift build reads the ROOT copy. Two containers, one dependency graph —
# if their pins drift, "CI tested X" silently becomes "release shipped Y".
# Fix: cp root pins' revisions into the workspace copy (values only), or open
# the workspace in Xcode once and commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="Package.resolved"
WS="ocoreai.xcworkspace/xcshareddata/swiftpm/Package.resolved"
[ -f "$ROOT" ] || { echo "❌ $ROOT missing"; exit 1; }
[ -f "$WS" ] || { echo "❌ $WS missing"; exit 1; }

python3 - "$ROOT" "$WS" "$1" <<'PY'
import json, sys
root_f, ws_f, mode = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "check")
root = json.load(open(root_f)); ws = json.load(open(ws_f))
rp = {p["identity"]: p for p in root["pins"]}
wp = {p["identity"]: p for p in ws["pins"]}
drift = []
for k in sorted(set(rp) | set(wp)):
    r, w = rp.get(k), wp.get(k)
    if r is None:
        drift.append((k, "MISSING", w["state"].get("revision", "")[:12])); continue
    if w is None:
        drift.append((k, r["state"].get("revision", "")[:12], "MISSING")); continue
    rr, wr = r["state"].get("revision", ""), w["state"].get("revision", "")
    if rr != wr:
        drift.append((k, rr[:12], wr[:12]))
if not drift:
    print("✅ resolved files in sync ({} pins)".format(len(rp))); raise SystemExit(0)
if mode == "sync":
    # values-only merge: root revisions win (CI release truth = root manifest).
    for i, p in enumerate(ws["pins"]):
        src = rp.get(p["identity"])
        if src is not None:
            ws["pins"][i]["state"] = dict(src["state"])
    for k, _, wrev in drift:
        if wrev == "MISSING" and k in rp:
            ws["pins"].append(dict(rp[k]))
    json.dump(ws, open(ws_f, "w"), indent=2, ensure_ascii=False)
    print("✅ synced {} drifting pins root→workspace".format(len(drift)))
    for k, a, b in drift: print("   {}: {} → {}".format(k, b, a))
    raise SystemExit(0)
print("❌ workspace resolved drifted from root ({} pins):".format(len(drift)))
for k, a, b in drift: print("   {} root={} ws={}".format(k, a, b))
print("fix: bash scripts/resolved-sync.sh sync")
raise SystemExit(1)
PY
