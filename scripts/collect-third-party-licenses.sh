#!/bin/zsh
# Collect third-party license texts for distribution (BSD-3 clause 2 / Apache-2.0 4).
#
# Why this exists: ocoreai redistributes (a) SPM dependencies and (b) source derived
# from apple/coreai-models (BSD-3-Clause). The derived files keep Apple's verbatim
# header, which points at "the LICENSE file" -- but this repo's LICENSE is MIT, so
# the BSD-3 conditions were not reproduced anywhere in the distribution. This script
# fixes that: it emits THIRD-PARTY-LICENSES/{NOTICES.md,<dep>.txt} and build-app.sh
# copies that folder into Contents/Resources, so the shipped .app carries the notices.
#
# Apple text is committed (Apple-coreai-models.txt) so CI, which has no ~/references
# clone, still ships it; when the clone IS available we byte-verify against upstream.
set -e
cd "$(dirname "$0")/.."
OUT=THIRD-PARTY-LICENSES
mkdir -p "$OUT"
APPLE="$OUT/Apple-coreai-models.txt"

# 1) Apple BSD-3 text: verify the committed copy against upstream when reachable.
REF="${OCOREAI_COREAI_MODELS_DIR:-$HOME/references/coreai-models}"
if [ -f "$REF/LICENSE" ] && [ -f "$APPLE" ]; then
  if cmp -s "$REF/LICENSE" "$APPLE"; then
    echo "OK   Apple BSD-3 text matches upstream coreai-models LICENSE"
  else
    echo "FAIL Apple BSD-3 text differs from upstream ($REF/LICENSE) -- refresh it"
    exit 1
  fi
elif [ -f "$APPLE" ]; then
  echo "SKIP Apple text verification (no coreai-models clone at $REF)"
else
  echo "FAIL $APPLE missing"
  exit 1
fi

# 2) Dependency texts from the resolved checkouts, pins read from Package.resolved.
BUILD=""
for c in .build-clt .build; do
  [ -d "$c/checkouts" ] && BUILD="$c" && break
done
if [ -z "$BUILD" ]; then
  echo "FAIL no SPM checkouts (.build-clt/checkouts or .build/checkouts) —"
  echo "     run 'swift build' first: this script reads license texts from the"
  echo "     resolved checkouts. Completeness of the committed texts is gated"
  echo "     independently by ThirdPartyNoticesTests, which needs no checkouts."
  exit 1
fi
python3 - "$BUILD" "$OUT" <<'PY'
import glob, hashlib, json, os, re, subprocess, sys
build, out = sys.argv[1], sys.argv[2]
res = json.load(open("Package.resolved"))
pins = {}
for p in res.get("pins", []):
    loc = p.get("location", "")
    name = p.get("identity") or loc.rstrip("/").split("/")[-1].replace(".git", "")
    st = p.get("state", {}) or {}
    pins[name] = st.get("version") or ("rev " + str(st.get("revision", ""))[:12]) or "?"
    pins[name + "|url"] = loc
def lic_kind(txt):
    t = txt[:1200]
    if "Apache License" in t and "Version 2.0" in t: return "Apache-2.0"
    # MIT's permission grant appears before the word "MIT" in some LICENSE files
    # (e.g. eventsource: the first line is the copyright), so match the text too.
    if "MIT" in t or "Permission is hereby granted, free of charge" in t: return "MIT"
    if "BSD-3" in t or "BSD 3-Clause" in t: return "BSD-3-Clause"
    if "ISC" in t: return "ISC"
    return "unidentified"
rows, wrote = [], 0
for name, ver in sorted(pins.items()):
    if name.endswith("|url"): continue
    d = os.path.join(build, "checkouts", name) if build else None
    txt, fn = None, None
    if d and os.path.isdir(d):
        for cand in sorted(os.listdir(d)):
            up = cand.upper()
            if up.startswith("LICENSE") or up.startswith("LICENCE") or up.startswith("COPYING"):
                fn = os.path.join(d, cand); break
    if fn:
        txt = open(fn, encoding="utf-8", errors="replace").read()
        dst = os.path.join(out, "%s.txt" % name)
        # Parens matter: `A if c else "" != txt` parses as `A if c else ("" != txt)`,
        # which is always truthy -- every run rewrote all texts (fake dirty tree).
        existing = open(dst, encoding="utf-8", errors="replace").read() if os.path.exists(dst) else ""
        if existing != txt:
            open(dst, "w", encoding="utf-8").write(txt); wrote += 1
        rows.append((name, ver, lic_kind(txt), "%s.txt" % name, pins.get(name + "|url", "")))
    else:
        rows.append((name, ver, "see upstream", "(not collected)", pins.get(name + "|url", "")))
# 3) Apple-derived counts, computed live (never hardcoded) and with an honest
#    metric: a file is redistributed under Apple's BSD-3 when it carries Apple's
#    copyright notice. Merely *mentioning* coreai-models in a comment is not
#    derivation, so the two signals are counted separately, the second one as an
#    intersection with the copyright signal.
def grep_files(pat):
    try:
        f = subprocess.run(["git","grep","-il",pat,"--","Sources"],capture_output=True,text=True).stdout.split()
        return {x for x in f}
    except Exception:
        return set()
apple_files = grep_files("Copyright 2026 Apple Inc")
mentions = {x.lower() for x in grep_files("coreai-models")}
apple_count = len(apple_files)
named_coreai = len([f for f in apple_files if f.lower() in mentions])

# 2c) Vendored headers under Sources/lib/ that belong to neither ocoreai (MIT) nor
#     Apple (BSD-3). Attribution is a human call, so the table is explicit — and a
#     third-party copyright line outside it fails the run instead of shipping an
#     unattributed grant (Apache-2.0 4 again: the text must travel with the copy).
VENDORED = {
    "Copyright (c) 2017 by Contributors": ("dmlc/dlpack", "Apache-2.0"),
}
def apache_body():
    # Canonical Apache-2.0 conditions, appendix stripped: the appendix is guidance
    # whose filled-in copyright line belongs to whoever wrote that file, not to the
    # component being attributed here.
    for f in sorted(glob.glob(os.path.join(out, "*.txt"))):
        t = open(f, encoding="utf-8", errors="replace").read()
        m = re.search(r"APPENDIX: How to apply", t, re.I)
        if "Apache License" in t[:400] and m:
            return t[:m.start()].rstrip() + "\n"
    return None
body = apache_body()
vendored, unattributed = {}, []
for dirpath, _, filenames in os.walk(os.path.join("Sources", "lib")):
    for fn in filenames:
        if not fn.endswith((".h", ".hpp", ".c", ".cpp", ".mm")):
            continue
        p = os.path.join(dirpath, fn)
        head = open(p, encoding="utf-8", errors="replace").read(2000)
        cl = [l for l in head.splitlines() if "Copyright" in l]
        if not cl:
            continue
        joined = " ".join(cl)
        if "Apple Inc." in joined or "uingei" in joined:
            continue
        known = [v for k, v in VENDORED.items() if k in joined]
        if not known:
            unattributed.append("%s :: %s" % (p, joined.strip()[:70]))
            continue
        upstream, spdx = known[0]
        tf = "Vendored-%s-%s.txt" % (upstream.split("/")[-1], spdx)
        if body:
            open(os.path.join(out, tf), "w", encoding="utf-8").write(body)
        holder = joined.strip().lstrip("*/").strip()[:60]
        vendored[p] = (upstream, spdx, holder, tf if body else "(no Apache body found)")
lines = []
lines.append("# Third-party notices for ocoreai\n")
lines.append("ocoreai's own code is MIT (see LICENSE). This product additionally ships:\n")
lines.append("## 1. Apple-derived source (BSD-3-Clause)\n")
lines.append("- Verbatim license text: `Apple-coreai-models.txt`, byte-compared against upstream `apple/coreai-models`' `LICENSE` by `scripts/collect-third-party-licenses.sh` whenever that clone is reachable.")
lines.append("- %d files under `Sources/` retain Apple's copyright notice together with its verbatim \"BSD-3-clause ... can be found in the LICENSE file\" header. Detection: `git grep -l \"Copyright 2026 Apple Inc\" -- Sources`." % apple_count)
lines.append("- Of those, %d name `coreai-models` in the header; the rest are Apple-authored files from other Apple trees (e.g. the XGrammar C bridge under `Sources/lib/CXGrammar/`), covered by the same BSD-3 text. `git grep -il coreai-models -- Sources` is deliberately NOT used as the count: %d hits include files that only mention the reference repo in a comment." % (named_coreai, len(mentions)))
lines.append("- The repo root `LICENSE` is MIT and covers only ocoreai's own code; here the BSD-3 conditions live in `NOTICES.md` + `Apple-coreai-models.txt`, next to this file. In the shipped app the folder sits at `ocoreai.app/Contents/Resources/THIRD-PARTY-LICENSES/`, and the GUI renders it under Settings \u2192 About \u2192 Third-Party Notices.\n")
lines.append("## 2. Linked SwiftPM dependencies\n")
lines.append("| dependency | pin | license | text |")
lines.append("|---|---|---|---|")
for n,v,k,f,u in rows:
    lines.append("| %s | %s | %s | %s |" % (n,v,k,f))
lines.append("\n## 3. Vendored headers under `Sources/lib/`\n")
for p, (upstream, spdx, holder, tf) in sorted(vendored.items()):
    lines.append("- `%s` — vendored from %s (%s), %s. Full text: `%s`." % (p, upstream, holder, spdx, tf))
if not vendored:
    lines.append("- none")
lines.append("- Rule: a copyright holder under `Sources/lib/` that is neither Apple nor the ocoreai author must be listed here, and the listed text file must exist. `scripts/audit.swift_patterns.sh` (Class-I) enforces it on every push.\n")
lines.append("\n## 4. openai/codex\n")
lines.append("- Not a dependency and not linked: codex is Rust. It is a **semantic** reference only; ocoreai contains behaviour equivalents, each cited in source comments (see `git grep -i codex -- Sources`). No codex source is redistributed, so no codex license text is bundled.\n")
lines.append("## 5. Apple frameworks (CoreAI etc.)\n")
lines.append("- System frameworks are linked at runtime by the OS and are not redistributed with this app; they are subject to Apple's platform terms.\n")
open(os.path.join(out,"NOTICES.md"),"w",encoding="utf-8").write("\n".join(lines)+"\n")
miss=[n for n,v,k,f,u in rows if f=="(not collected)"]
def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

# Which upstream revision does the shipped Apple text correspond to? The reference clone
# is host-local (absent on CI and in a fresh clone), so the pin is recorded when the
# clone can answer and null when it cannot -- never guessed. `git show <pin>:LICENSE`
# re-opens that exact tree, so the byte-identity claim survives after the clone's HEAD
# moves on, which is exactly what a bare "verified at collection time" could not do.
# Borrowed from harness2's third_party/PROVENANCE.md + dependencies/ASSETS.json habit:
# vendored bytes carry their source and a hash, and a script re-checks them.
apple_pin, apple_match = None, None
apple_file = os.path.join(out, "Apple-coreai-models.txt")
for cand in (os.path.expanduser("~/references/coreai-models"), "coreai-models"):
    if not os.path.isdir(os.path.join(cand, ".git")):
        continue
    head = subprocess.run(["git", "-C", cand, "rev-parse", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    upstream_text = subprocess.run(["git", "-C", cand, "show", "%s:LICENSE" % head],
                                   capture_output=True)
    if not head or upstream_text.returncode != 0:
        continue
    apple_pin = head
    apple_match = hashlib.sha256(upstream_text.stdout).hexdigest() == sha256(apple_file)
    break

manifest = {
    "schemaVersion": 2,
    "apple": {
        "upstream": "apple/coreai-models",
        "license": "BSD-3-Clause",
        "licenseFile": "Apple-coreai-models.txt",
        "licenseSha256": sha256(apple_file) if os.path.exists(apple_file) else None,
        "verifiedAgainstPin": apple_match,
        "pin": apple_pin,
    },
    "dependencies": [
        {"name": n, "pin": v, "license": k, "textFile": f, "repository": u}
        for n, v, k, f, u in rows
    ],
    # Vendored bytes are the redistribution this repo hand-carries: no SwiftPM pin, no
    # checkout, nothing upstream to re-resolve them against. Until now the manifest
    # described only Apple + dependencies, so the machine-readable index omitted the
    # Apache-2.0 header the product ships (NOTICES.md listed it; manifest.json did not),
    # and the GUI showed neither.
    "vendored": [
        {
            "file": p,
            "upstream": upstream,
            "license": spdx,
            "holder": holder,
            "textFile": tf,
            "sha256": sha256(p) if os.path.exists(p) else None,
        }
        for p, (upstream, spdx, holder, tf) in sorted(vendored.items())
    ],
}
with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")
print("deps=%d  texts_written=%d  missing=%s  apple_derived_files=%d  naming_coreai=%d"
      % (len(rows), wrote, miss or "none", apple_count, named_coreai))
print("provenance: apple_pin=%s  byte_identical_at_pin=%s  vendored=%d"
      % (apple_pin or "<clone not present>", apple_match, len(vendored)))
# Gate: BSD-3 clause 2 / Apache-2.0 4 require the text to travel with the
# distribution, so a dependency without a collected text is a build failure,
# not a footnote -- a silent gap here is a license violation users cannot see.
if miss:
    for n in miss:
        print("FAIL no license text found for dependency: %s" % n)
    sys.exit(1)
if unattributed:
    for n in unattributed:
        print("FAIL third-party copyright under Sources/lib not in the vendored table: %s" % n)
    sys.exit(1)
PY
