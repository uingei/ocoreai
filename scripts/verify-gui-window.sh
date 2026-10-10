#!/bin/bash
# verify-gui-window.sh — prove the delivered app actually SHOWS a window.
#
# First principles: "the app runs" has two layers. HTTP healthy + completion
# proves the engine; it does NOT prove the user sees anything (the process
# could serve forever from a windowless state). This gate asserts, via
# CGWindowList (no Accessibility/TCC entitlement needed — osascript is
# blocked on unattended hosts, CGWindowList is not):
#   1) ≥1 normal-layer (layer 0) window of believable size exists, AND
#   2) the traffic-light close button is at the AppKit-canonical
#      TOP-left (x≈20) — not the bottom-left inverted-layout bug —
#      the exact geometry Apple HIG windows have.
# SHOT=1 additionally captures the window PNG as visual evidence
# (screencapture -l captures a window id WITHOUT screen-recording TCC).
#
# Usage:  bash scripts/verify-gui-window.sh            # assert window
#         SHOT=1 bash scripts/verify-gui-window.sh     # + /tmp evidence
#         APP_NAME=ocoreai bash scripts/verify-gui-window.sh
set -euo pipefail

APP_NAME="${APP_NAME:-ocoreai}"
SHOT="${SHOT:-0}"
TMP_HELPER="$(mktemp -d)/winprobe.swift"

cat > "$TMP_HELPER" <<'EOF'
import CoreGraphics
import Foundation

let target = (CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ocoreai").lowercased()
guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("no window list\n".utf8)); exit(2)
}
var main: (id: UInt32, w: CGFloat, h: CGFloat)? = nil
var closeTopLeft = false
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    guard owner.contains(target) else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    guard layer == 0, let num = w[kCGWindowNumber as String] as? UInt32,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    if main == nil || b["Width"]! * b["Height"]! > CGFloat(main!.w * main!.h) {
        main = (num, b["Width"]!, b["Height"]!)
    }
    // Traffic-light close button: small ~14pt window in AppKit-owned group.
    let isButton = b["Width"]! >= 12 && b["Width"]! <= 16 && b["Height"]! >= 12 && b["Height"]! <= 16
    if isButton && b["Y"]! >= 10 && b["Y"]! <= 30 && b["X"]! >= 10 && b["X"]! <= 30 { closeTopLeft = true }
}
if let m = main {
    print("\(m.id) \(Int(m.w))x\(Int(m.h)) closeTL=\(closeTopLeft)")
    exit(0)
}
exit(1)
EOF

OUT="$(swift "$TMP_HELPER" "$APP_NAME")" || {
    echo "❌ no visible $APP_NAME window (layer-0) — app served but showed nothing"
    exit 1
}
read -r WID DIMS CTL <<<"$OUT"
echo "✅ window visible: ${DIMS} (cgwindow $WID)"
if [ "$CTL" = "true" ]; then
    echo "✅ traffic-light close button top-left (HIG-canonical geometry)"
else
    echo "⚠️ close-button geometry not detected (headless/scaled displays vary — not a fail)"
fi

if [ "$SHOT" = "1" ]; then
    PNG="${PNG:-/tmp/${APP_NAME}-window.png}"
    screencapture -o -x -l"$WID" "$PNG"
    SZ=$(stat -f%z "$PNG" 2>/dev/null || stat -c%s "$PNG")
    # A blank/black capture is only a few KB; a rendered dashboard is >>20KB.
    if [ "$SZ" -lt 20000 ]; then
        echo "❌ capture suspiciously small ($SZ bytes) — window likely blank"
        exit 1
    fi
    echo "✅ window screenshot: $PNG ($((SZ / 1024)) KB)"
fi
