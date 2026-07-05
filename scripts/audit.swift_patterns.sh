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
    # Step 3: exclude whitelist patterns (pipe-separated fixed strings)
    local first_pass
    first_pass=$(grep -rEn "$pattern" "$SRC" --include='*.swift' 2>/dev/null \
        | grep -v '///')
    if [ -z "$first_pass" ]; then
        echo "  ✅ Clean"
        return
    fi
    # Filter out whitelist entries — each is a fixed-string pattern to exclude
    if [ -n "$whitelist" ]; then
        local cleaned="$first_pass"
        IFS='|' read -ra WL_PARTS <<< "$whitelist"
        for part in "${WL_PARTS[@]}"; do
            cleaned=$(echo "$cleaned" | grep -vF "$part" || true)
        done
        # Count non-empty lines — avoids "echo '' | wc -l" returning 1
        count=$(echo "$cleaned" | grep -c . || true)
    else
        count=$(echo "$first_pass" | grep -c . || true)
    fi
    if [ "$count" -gt 0 ]; then
        echo "  ❌ $count violation(s)"
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

# --- Class-B: Hardcoded UI strings (user-facing only) ---
# Only flag lines from: AppState.swift, StatusPill.swift, StatusView.swift, SettingsStore.swift, AppTabs, Views/
check "Class-B: Hardcoded UI in view layer" \
    'return\s*"[A-Z][a-z]' \
    "Localization.swift|systemName|SystemName|errorDescription|ToolEntry|DownloadManager|ConfigStruct|KeychainStore|Scheduler|MCPServer|OpenAIModels|ModelScopeDownloader|HuggingFaceDownloader|SQLiteStore|SkillModels|MLXBridge|CoreAIBridge|EngineInference|Profiling"

# --- Class-A: Empty catch ---
check "Class-A: Empty catch" 'catch\s*{[[:space:]]*}' \
    "ErrorContext|EngineInference"

# --- Class-D: URL(string:)! ---
check "Class-D: URL(string:)!" 'URL\\(string:.*!' \
    "defaultURL|makeURL|safe|ModelScopeSearchClient"

echo ""
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ All audits passed"
    exit 0
else
    echo "❌ Some classes have violations"
    exit 1
fi
