#!/bin/bash
# Audit: systematic failure patterns in ocoreai
# Exit 0 = clean, 1 = violations

ROOT="${1:-.}"
SRC="$ROOT/Sources/"
FAIL=0

echo "🔍 ocoreai static audit"
echo "=========================================="

check() {
    local label="$1" pattern="$2" whitelist="$3"
    echo ""
    echo "[$label]"
    local count
    # Step 1: grep pattern in Swift source
    # Step 2: exclude doc-comment lines (///)
    # Step 3: exclude whitelist patterns (inline pipe-separated + the whitelist file)
    local first_pass
    first_pass=$(grep -rEn "$pattern" "$SRC" --include='*.swift' 2>/dev/null \
        | grep -v '///')
    if [ -z "$first_pass" ]; then
        echo "  ✅ Clean"
        return
    fi
    # Exclusions come from two places, and every run prints how much it removed: the
    # inline list (3rd arg, pipe-separated) and scripts/audit_whitelist.txt, whose own
    # header promises "one excluded path per line … that the audit grep will skip via
    # -F match". That file was declared and touched but never read, so an entry added
    # there bought silence that was not real. Printing raw → remaining is what keeps a
    # Clean honest: without it, "nothing matches the pattern" and "15 hits, all 15
    # whitelisted" render identically, and only the first means the code is free of it.
    local raw cleaned entry
    raw=$(echo "$first_pass" | grep -c . || true)
    cleaned="$first_pass"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        cleaned=$(echo "$cleaned" | grep -vF "$entry" || true)
    done <<EOF
$(printf '%s\n' "$whitelist" | tr '|' '\n')
$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WHITELIST" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
EOF
    # Count non-empty lines — avoids "echo '' | wc -l" returning 1
    count=$(echo "$cleaned" | grep -c . || true)
    echo "  scan: $raw hit(s), $((raw - count)) whitelisted → $count violation(s)"
    if [ "$count" -gt 0 ]; then
        echo "  ❌ $count violation(s)"
        # Show what is left, capped — a gate that reports only a number cannot be
        # triaged without re-running the grep by hand.
        echo "$cleaned" | head -20 | sed 's/^/     /'
        if [ "$count" -gt 20 ]; then
            echo "     … $((count - 20)) more (re-run the grep in check() for the full list)"
        fi
        FAIL=1
    else
        echo "  ✅ Clean"
    fi
}

# whitelist file
WHITELIST="$ROOT/scripts/audit_whitelist.txt"
touch "$WHITELIST" 2>/dev/null || true

# --- Class-F: .first! force unwrap ---
check "Class-F: .first! force unwrap" '\.first!' \
    "test|Test"

# --- Class-B: hardcoded UI strings in the view layer ---
# The class is named for the view layer, so it scans the view layer. Scanning all of
# Sources/ instead made it a gate in name only: measured 10-15, 97 hits, 97 whitelisted,
# 0 of them in a view. Every line it ever flagged was an enum's errorDescription or a
# domain label in Engine/, Video/, Multimodal/ or Capability/ — a 100% exemption rate,
# which means the whitelist had become the scan and the pattern could only ever catch
# what it was then told to excuse. Scoping to the module boundary keeps the promise the
# label makes: a view that returns a display-string literal instead of a StringKey fails
# here, and an engine error enum never has to be excused again.
# Views localize through StringKey (`.l`): String(localized:) appears 0 times under UI/,
# so `.l` is the live convention this gate protects.
# The floor is the premise check (AGENTS.md invariant 1) — a scan over a moved or pruned
# view layer finds nothing, so the number of files it scanned is printed and floored.
echo ""
echo "[Class-B: hardcoded UI string in the view layer]"
VIEW_ROOT="$ROOT/Sources/ocoreai/UI"
MIN_UI_FILES=40
if [ ! -d "$VIEW_ROOT" ]; then
    echo "  ❌ view layer missing: $VIEW_ROOT"
    FAIL=1
else
    ui_files=$(find "$VIEW_ROOT" -name '*.swift' | sort)
    ui_count=$(echo "$ui_files" | grep -c . || true)
    if [ "$ui_count" -lt "$MIN_UI_FILES" ]; then
        echo "  ❌ only $ui_count .swift under $VIEW_ROOT (floor $MIN_UI_FILES)"
        echo "     the view layer moved or was pruned — an empty scan proves nothing"
        FAIL=1
    else
        b_hits=$(echo "$ui_files" | xargs grep -nE 'return[[:space:]]+"[A-Z][a-z]' 2>/dev/null \
            | grep -vE ':[0-9]+: *(//|/\*|\*)' || true)
        if [ -n "$b_hits" ]; then
            echo "  ❌ $(echo "$b_hits" | grep -c . || true) violation(s) — return a StringKey, not a literal"
            echo "$b_hits" | sed 's/^/     /'
            FAIL=1
        else
            echo "  ✅ Clean ($ui_count view files scanned, 0 hardcoded display returns)"
        fi
    fi
fi

# --- Class-A: Empty catch ---
check "Class-A: Empty catch" 'catch\s*{[[:space:]]*}' \
    "ErrorContext|EngineInference"

# --- Class-D: URL(string:)! ---
check "Class-D: URL(string:)!" 'URL\\(string:.*!' \
    "defaultURL|makeURL|safe|ModelScopeSearchClient"

# --- Class-G: Hardcoded version literal — version truth flows through
# AppInfo.shortVersion / the git-tag pipeline, never a source literal.
# (Shipped bug 2026-10: About said v1.0.0, metrics said 1.0.0, MCP said
# 0.7.0 — three frozen mouths while v0.1.6 was on the wire.)
# Pattern is unquoted so /// doc-comment mentions are filtered by check().
check "Class-G: hardcoded version literal" '"v\?[0-9]\+\.[0-9]\+\.[0-9]\+"' \
    "AppInfo.swift|0.0.4"


# --- Class-H: MLX buffer-cache limit must have exactly one owner ---
# App boot also used to write its scheduler budget (70 GB on a 128 GB host) into
# Memory.cacheLimit; the loader's later 256 MB write won, so the log claimed a
# 70 GB cache ceiling that never applied — and a budget-sized cache measured
# ~2x slower (23.7 vs 42-46 tok/s, M5 Max, gemma-4-e2b-it-4bit), because MLX
# then keeps freed device buffers resident instead of handing them back.
# Owner = MLXModelLoader (Engine/MLXBridge.swift); any second writer fails here.
check "Class-H: Memory.cacheLimit written outside its owner" 'Memory\.cacheLimit[[:space:]]*=' \
    "MLXBridge.swift"

# --- Class-I: redistribution notices must stay accurate ---
# BSD-3 cl.1 / Apache-2.0 4 attach to the notice itself, and THIRD-PARTY-LICENSES/
# is the only place the shipped product states them. Three failure modes this pins:
# a mojibake or misspelled rightsholder (a notice that names nobody correct), and a
# vendored header whose holder appears nowhere in the notices (an unattributed grant).
echo ""
echo "[Class-I: redistribution notice integrity]"
NOTICES="$ROOT/THIRD-PARTY-LICENSES/NOTICES.md"
I_FAIL=0
if [ ! -f "$NOTICES" ]; then
    echo "  ❌ $NOTICES missing — run scripts/collect-third-party-licenses.sh"
    I_FAIL=1
fi
broken=$(grep -rn "Copyright ?\|uigei@\|Copyright @[[:space:]]*$" "$SRC" \
    --include='*.swift' --include='*.h' --include='*.cpp' 2>/dev/null || true)
if [ -n "$broken" ]; then
    echo "  ❌ malformed rightsholder line:"
    echo "$broken" | sed 's/^/     /'
    I_FAIL=1
fi
LIBDIR="$ROOT/Sources/lib"
if [ -d "$LIBDIR" ] && [ -f "$NOTICES" ]; then
    for f in $(grep -rl "Copyright" "$LIBDIR" --include='*.h' --include='*.hpp' \
            --include='*.c' --include='*.cpp' --include='*.mm' 2>/dev/null || true); do
        if grep -q "Apple Inc.\|uingei" "$f"; then continue; fi
        case "$f" in
            *"$ROOT"*) rel="${f#$ROOT/}" ;;
            *) rel="$f" ;;
        esac
        if ! grep -qF "$rel" "$NOTICES"; then
            echo "  ❌ vendored third-party file not attributed in NOTICES.md: $rel"
            I_FAIL=1
        fi
    done
fi
# Provenance: attribution says whose it is; a hash says *which bytes*. BSD-3 and
# Apache-2.0 4 both attach to the copy that travels, so "verified against upstream at
# collection time" has to name the revision and the digest or no later session can tell
# which upstream it meant. The reference clone is host-local, so upstream byte-identity
# counts as a loud SKIP when the clone is absent -- never as a pass, never as a silence.
MANIFEST="$ROOT/THIRD-PARTY-LICENSES/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "  ❌ $MANIFEST missing — run scripts/collect-third-party-licenses.sh"
    I_FAIL=1
else
    PROV_LOG="$(mktemp -t ocoreai-provenance-XXXXXX)"
    python3 - "$MANIFEST" "$ROOT" > "$PROV_LOG" 2>&1 <<'PYPROV'
import hashlib, json, os, subprocess, sys

manifest_path, root = sys.argv[1], sys.argv[2]
fails, oks, skips = [], [], []


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


try:
    m = json.load(open(manifest_path, encoding="utf-8"))
except Exception as exc:  # noqa: BLE001 - report, never crash the gate
    print("FAIL manifest.json unreadable: %s" % exc)
    sys.exit(1)

if m.get("schemaVersion", 0) < 2:
    fails.append("manifest schemaVersion=%s < 2 — provenance fields (pin/sha256/vendored) are absent; "
                 "re-run scripts/collect-third-party-licenses.sh" % m.get("schemaVersion"))

apple = m.get("apple") or {}
aff = apple.get("licenseFile")
if not aff:
    fails.append("manifest.apple has no licenseFile")
else:
    apath = os.path.join(os.path.dirname(manifest_path), aff)
    if not os.path.exists(apath):
        fails.append("Apple license text not on disk: %s" % aff)
    else:
        digest = sha(apath)
        if apple.get("licenseSha256") != digest:
            fails.append("Apple license text changed since collection: recorded %s… now %s…"
                        % (str(apple.get("licenseSha256"))[:12], digest[:12]))
        else:
            oks.append("Apple license text matches its recorded sha256 (%s…)" % digest[:12])

pin = apple.get("pin")
if not pin:
    skips.append("apple.pin is null — the coreai-models clone was not present when the text was "
                 "collected, so upstream byte-identity is unverified for this manifest")
else:
    clone = None
    for cand in (os.path.expanduser("~/references/coreai-models"), "coreai-models"):
        if os.path.isdir(os.path.join(cand, ".git")):
            clone = cand
            break
    if clone is None:
        skips.append("coreai-models clone not on this host — apple.pin=%s could not be re-opened "
                     "(recorded claim preserved, not re-verified here)" % pin[:11])
    else:
        up = subprocess.run(["git", "-C", clone, "show", "%s:LICENSE" % pin], capture_output=True)
        if up.returncode != 0:
            fails.append("apple.pin=%s is not a readable object in %s — the recorded provenance "
                         "cannot be re-checked" % (pin[:11], clone))
        elif hashlib.sha256(up.stdout).hexdigest() != (apple.get("licenseSha256") or ""):
            fails.append("Apple text is NOT byte-identical to upstream LICENSE at %s — either the "
                         "text drifted or the pin was recorded against the wrong tree" % pin[:11])
        else:
            oks.append("Apple text byte-identical to apple/coreai-models LICENSE at %s" % pin[:11])

vend = m.get("vendored")
if vend is None:
    fails.append("manifest has no `vendored` array — the machine-readable index omits the "
                 "redistribution the product hand-carries")
elif len(vend) < 1:
    fails.append("manifest.vendored is empty while Sources/lib/ ships third-party code — a scan "
                 "that matches nothing certifies nothing")
else:
    bad = 0
    for v in vend:
        f = v.get("file") or ""
        path = os.path.join(root, f)
        if not os.path.exists(path):
            fails.append("vendored file listed in manifest but absent: %s" % f)
            bad += 1
            continue
        digest = sha(path)
        if v.get("sha256") != digest:
            fails.append("vendored bytes changed since collection: %s (recorded %s… now %s…)"
                        % (f, str(v.get("sha256"))[:12], digest[:12]))
            bad += 1
            continue
        tf = v.get("textFile") or ""
        if not os.path.exists(os.path.join(os.path.dirname(manifest_path), tf)):
            fails.append("vendored %s names license text %s, which is not bundled" % (f, tf))
            bad += 1
            continue
        if not v.get("upstream"):
            fails.append("vendored %s records no upstream — provenance with no source" % f)
            bad += 1
            continue
    if bad == 0:
        oks.append("all %d vendored file(s) match their recorded sha256, upstream and text file"
                  % len(vend))

for line in oks:
    print("OK %s" % line)
for line in skips:
    print("SKIP %s" % line)
for line in fails:
    print("FAIL %s" % line)
sys.exit(1 if fails else 0)
PYPROV
    PROV_RC=$?
    sed 's/^/     /' "$PROV_LOG"
    rm -f "$PROV_LOG"
    if [ "$PROV_RC" -ne 0 ]; then
        I_FAIL=1
    fi
fi

if [ "$I_FAIL" -eq 0 ]; then
    echo "  ✅ Clean"
    grep -c "^| " "$NOTICES" 2>/dev/null | sed 's/^/     notices table rows: /'
fi
FAIL=$((FAIL + I_FAIL))

echo ""
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ All audits passed"
    exit 0
else
    echo "❌ Some classes have violations"
    exit 1
fi
