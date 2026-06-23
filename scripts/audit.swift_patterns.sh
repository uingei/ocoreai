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
    count=$(grep -rEn "$pattern" "$SRC" --include='*.swift' 2>/dev/null \
        | grep -vFw "$whitelist" \
        | wc -l)
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
    "ErrorContext"

# --- Class-D: URL(string:)! ---
check "Class-D: URL(string:)!" 'URL\(string:.*!' \
    "defaultURL|makeURL|safe"

echo ""
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ All audits passed"
    exit 0
else
    echo "❌ Some classes have violations"
    exit 1
fi
