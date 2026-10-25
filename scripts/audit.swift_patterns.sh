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

# --- Premise: every whitelist entry must point at a live path ---
# The whitelist is the loudest part of this gate, so it needs its own premise check
# (AGENTS.md invariant 1). An entry whose path no longer exists is not an exemption, it is
# a loaded silence: the day a file reuses that name, the audit waves it through — and the
# rationale above it keeps explaining, at length, why a defect that isn't there is forgiven.
# Measured 10-20: `ErrorContext` was one such entry (the file it excused had been deleted;
# grep = 0 in Sources/), found the same hour Class-J started resolving suite-name claims.
echo ""
echo "[Premise: whitelist entries point at live paths]"
W_ENTRIES=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$WHITELIST" \
    | grep -v '^[[:space:]]*$' || true)
W_TOTAL=$(printf '%s\n' "$W_ENTRIES" | grep -c . || true)
W_DEAD=0
while IFS= read -r wentry; do
    [ -n "$wentry" ] || continue
    if ! grep -rlF --include='*.swift' "$wentry" "$SRC" 2>/dev/null | grep -q .; then
        echo "  ❌ dead entry: $wentry matches no file in $SRC — prune it, or restore the defect it excuses"
        W_DEAD=$((W_DEAD + 1))
    fi
done <<WEOF
$W_ENTRIES
WEOF
echo "  scan: $W_TOTAL exemption entries, $W_DEAD dead"
if [ "$W_DEAD" -gt 0 ]; then
    FAIL=1
else
    echo "  ✅ Clean"
fi

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

# --- Class-J: a comment that names a test suite is a claim about Tests/ ---
# Provenance (10-20, found while auditing codex #55581): a comment in
# Engine/CoreAIPipelinedEngine.swift stated its encode gate was "exercised by
# `PipelineGateTests`". No such suite existed — and none could have: the entire file sat
# inside one file-level `#if canImport(CoreAI)`, so on the macOS 26 SDK that ships (and on
# CI) the type was compiled out and a suite for it could not compile either. Nothing in the
# repo could go red for that sentence, so under invariant 1 it was not a claim. This class
# makes the whole genus one: every `…Tests` identifier named in a Sources/ comment must
# resolve to a suite that exists — declared in Tests/ (struct/class/actor/extension) or a
# Tests/**/<name>.swift file — or, when the comment cites upstream provenance, to a suite in
# a dependency checkout or ~/references clone. Upstream resolution is a loud SKIP when no tree
# is present: unverifiable is never a pass, and never a silence either.
echo ""
echo "[Class-J: test-suite claims in comments resolve to a real suite]"
J_TESTS="$ROOT/Tests"
J_FLOOR=20
if [ ! -d "$J_TESTS" ]; then
    echo "  ⚠️  SKIP: no $J_TESTS in $ROOT — claims cannot be resolved (not a pass)"
else
    J_FAIL=0
    J_CLAIMS=$(mktemp)
    J_LINES=$(mktemp)
    # Comment lines only: `//…` or a doc-comment continuation ` * …`. Sources/ is the side
    # that makes the promise; Tests/ is the side that has to keep it.
    grep -rn --include='*.swift' -E '(//|\*)[^"]*[A-Za-z0-9_]*Tests\b' "$SRC" 2>/dev/null \
        > "$J_LINES" || true
    grep -oE '[A-Za-z0-9_]*Tests\b' "$J_LINES" | sort -u > "$J_CLAIMS" || true
    J_TOTAL=$(grep -c . "$J_CLAIMS" || true)
    echo "  scan: $J_TOTAL distinct suite name(s) claimed in Sources/ comments (floor $J_FLOOR)"
    if [ "$J_TOTAL" -lt "$J_FLOOR" ]; then
        echo "  ❌ scan premise unmet: a comment layer this thin means the pattern stopped matching"
        J_FAIL=1
    fi
    # Directory names under Tests/ (the module dir, `Tests` itself) are path references,
    # not suite claims — derived, never hand-listed, so a renamed module cannot leave the
    # exclusion pointing at nothing.
    J_DIRS=$(find "$J_TESTS" -maxdepth 1 -type d 2>/dev/null | xargs -n1 basename | sort -u)
    J_TREES=""
    for t in "$ROOT"/.build/checkouts/* "$ROOT"/.build-clt/checkouts/* "$HOME"/references/*; do
        [ -d "$t" ] && J_TREES="$J_TREES $t"
    done
    J_LOCAL=0 J_UP=0 J_SKIP=0 J_BAD=0
    while IFS= read -r jname; do
        [ -n "$jname" ] || continue
        if printf '%s\n' "$J_DIRS" | grep -qxF "$jname"; then
            J_LOCAL=$((J_LOCAL + 1)); continue
        fi
        if grep -rEl "(struct|final class|class|actor|extension)[[:space:]]+${jname}[[:space:]:{]" \
                "$J_TESTS" --include='*.swift' 2>/dev/null | grep -q . \
           || find "$J_TESTS" -name "${jname}.swift" 2>/dev/null | grep -q .; then
            J_LOCAL=$((J_LOCAL + 1)); continue
        fi
        jhit=""
        if [ -n "$J_TREES" ]; then
            for t in $J_TREES; do
                if find "$t" -name "${jname}.swift" -not -path '*/.git/*' 2>/dev/null | grep -q .; then
                    jhit=$(basename "$t"); break
                fi
            done
        fi
        if [ -n "$jhit" ]; then
            echo "  OK (upstream) $jname — resolves in the $jhit clone; kept as provenance"
            J_UP=$((J_UP + 1))
        elif [ -n "$J_TREES" ]; then
            echo "  ❌ UNRESOLVED $jname — named in a Sources/ comment, absent from Tests/ and every checkout"
            grep -nE "[A-Za-z0-9_]*${jname}\b" "$J_LINES" | head -3 | sed 's/^/       /'
            J_BAD=$((J_BAD + 1))
        else
            echo "  ⚠️  SKIP $jname — no dependency checkout here to resolve an upstream claim"
            J_SKIP=$((J_SKIP + 1))
        fi
    done < "$J_CLAIMS"
    echo "  resolve: $J_LOCAL local, $J_UP upstream, $J_SKIP unverifiable, $J_BAD unresolved"
    if [ "$J_BAD" -gt 0 ]; then
        echo "  ❌ $J_BAD claim(s) name a suite that does not exist — add the suite, or name the gate that does"
        J_FAIL=1
    fi
    if [ "$J_FAIL" -eq 0 ]; then echo "  ✅ Clean"; fi
    FAIL=$((FAIL + J_FAIL))
    rm "$J_CLAIMS" "$J_LINES"
fi


# --- Class-K: a colored emoji is not an icon ---
# The GUI's judge is the HIG (AGENTS.md, Upstream Audit Dependencies 5), and the platform draws
# this line by *presentation*, not by taste: U+FE0F and the Emoji_Presentation property are
# exactly the codepoints that render as fixed-color pictographs, which a control cannot restyle
# for Dark Mode, tint or Dynamic Type. Upstream writes the same rule down: pi "No emojis in
# commits, issues, PR comments, or code" (references/pi/AGENTS.md:6); sglang "No decorative
# formatting or emoji" (references/sglang/docs/AGENTS.md:281); opencode routes every icon field
# through a named catalog rather than free text (references/opencode/packages/gui-extensions/
# AGENTS.md:13).
# Text-presentation marks stay where they are punctuation, not pictures: U+2193 arrow, U+2605
# star, U+00B7 middle dot all render monochrome and inherit font, weight and colour.
# Mechanism: perl, which ships with the macOS toolchain. grep -E has no Unicode property class and
# a hand-typed byte list is precisely the regex that quietly stops matching (invariant 1), so the
# expression is run against two known pictographs in-process first: a perl too old for
# Emoji_Presentation, or a source tree that moved, fails here instead of reporting a Clean scan
# that never scanned.
echo ""
echo "[Class-K: colored pictographs in code; icons are SF Symbols]"
K_MIN_FILES=250
K_WHITELIST='SentimentAnalyzer.swift'
if ! command -v perl >/dev/null 2>&1; then
    echo "  X perl is not on PATH - the Unicode-property scan cannot run (an unrun scan is not a Clean)"
    FAIL=1
else
    K_PROBE=$(perl -CSD -e 'my $n = 0; $n++ if "\x{2B50}" =~ /\p{Emoji_Presentation}/; $n++ if "\x{26A0}\x{FE0F}" =~ /\x{FE0F}/; print $n')
    if [ "$K_PROBE" != "2" ]; then
        echo "  X this perl does not match the pattern against two known pictographs (probe=$K_PROBE/2)"
        FAIL=1
    else
        K_FILES=$(find "$SRC" -name '*.swift' | grep -c . || true)
        echo "  scan: $K_FILES .swift file(s), floor $K_MIN_FILES, perl probe $K_PROBE/2"
        if [ "$K_FILES" -lt "$K_MIN_FILES" ]; then
            echo "    scan premise unmet: the source tree moved or was pruned - a thin scan proves nothing"
            FAIL=1
        fi
        # An exemption that no longer names a live file is a loaded silence (same premise check the
        # shared whitelist gets above), so it is checked here too rather than trusted.
        K_DEAD=0
        while IFS= read -r kentry; do
            [ -n "$kentry" ] || continue
            if ! find "$SRC" -name "$kentry" 2>/dev/null | grep -q .; then
                echo "    X dead exemption: $kentry matches no file in $SRC - prune it"
                K_DEAD=$((K_DEAD + 1))
            fi
        done <<KEOF
$(printf '%s\n' "$K_WHITELIST" | tr '|' '\n')
KEOF
        FAIL=$((FAIL + K_DEAD))
        K_HITS=$(find "$SRC" -name '*.swift' -print0 | xargs -0 perl -CSD -ne \
            'print "$ARGV:$.: $_" if /\p{Emoji_Presentation}|\x{FE0F}/; close ARGV if eof;' 2>/dev/null \
            | grep -vE ':[0-9]+: *(//|/\*|\*)' || true)
        K_RAW=$(printf '%s\n' "$K_HITS" | grep -c . || true)
        K_CLEAN="$K_HITS"
        while IFS= read -r kentry; do
            [ -n "$kentry" ] || continue
            K_CLEAN=$(printf '%s\n' "$K_CLEAN" | grep -vF "$kentry" || true)
        done <<KEOF2
$(printf '%s\n' "$K_WHITELIST" | tr '|' '\n')
KEOF2
        K_COUNT=$(printf '%s\n' "$K_CLEAN" | grep -c . || true)
        echo "  result: $K_RAW line(s) with a pictograph, $((K_RAW - K_COUNT)) exempt (emoji AS the data) -> $K_COUNT violation(s)"
        if [ "$K_COUNT" -gt 0 ]; then
            printf '%s\n' "$K_CLEAN" | head -10 | sed 's/^/     /'
            echo "  X $K_COUNT violation(s) - use Image(systemName:), a text-presentation glyph, or say why emoji IS the data"
            FAIL=1
        else
            echo "  Clean"
        fi
    fi
fi

echo ""
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ All audits passed"
    exit 0
else
    echo "❌ Some classes have violations"
    exit 1
fi
