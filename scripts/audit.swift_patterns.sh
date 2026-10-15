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
