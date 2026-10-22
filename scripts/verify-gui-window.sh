#!/bin/bash
# verify-gui-window.sh — prove the delivered app actually SHOWS a window.
#
# First principles: "the app runs" has two layers. HTTP healthy + completion
# proves the engine; it does NOT prove the user sees anything (the process
# could serve forever from a windowless state). This gate asserts, via
# CGWindowList (no Accessibility/TCC entitlement needed — osascript is
# blocked on unattended hosts, CGWindowList is not):
#   1) ≥1 normal-layer (layer 0) window of believable size exists, and
#   2) with SHOT=1, the captured frame is actually rendered (distinct-colour floor), not a
#      blank/black surface that merely has a size.
#
# A traffic-light/close-button assertion lived here until 10-22 and is gone on purpose: AppKit
# title-button sub-windows are not enumerable in an unattended session (owned entries measured
# 0), so the check could only ever print ⚠️. A check that cannot pass carries no signal and
# trains everyone to ignore the ones that can — deleting it is the fix. A pixel-band variant
# was tried and rejected too (it found 1 of 3 discs; inactive discs sit ~25/255 from the
# sidebar tone). The provable statement is layer-0 geometry + a rendered frame.
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
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
    guard owner.contains(target) else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    guard layer == 0, let num = w[kCGWindowNumber as String] as? UInt32,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    if main == nil || b["Width"]! * b["Height"]! > CGFloat(main!.w * main!.h) {
        main = (num, b["Width"]!, b["Height"]!)
    }
}
if let m = main {
    print("\(m.id) \(Int(m.w))x\(Int(m.h))")
    exit(0)
}
exit(1)
EOF

OUT="$(swift "$TMP_HELPER" "$APP_NAME")" || {
    echo "❌ no visible $APP_NAME window (layer-0) — app served but showed nothing"
    exit 1
}
read -r WID DIMS <<<"$OUT"
echo "✅ window visible: ${DIMS} (cgwindow $WID)"

if [ "$SHOT" = "1" ]; then
    PNG="${PNG:-/tmp/${APP_NAME}-window.png}"
    screencapture -o -x -l"$WID" "$PNG"
    SZ=$(stat -f%z "$PNG" 2>/dev/null || stat -c%s "$PNG")
    # A blank/black capture is only a few KB; a rendered dashboard is >>20KB.
    if [ "$SZ" -lt 20000 ]; then
        echo "❌ capture suspiciously small ($SZ bytes) — window likely blank"
        exit 1
    fi
    # Size alone only proves bytes; a solid fill compresses small and a gradient compresses
    # large. Count distinct colours in the frame instead: a rendered SwiftUI window has
    # thousands (antialiased text, vibrancy, traffic lights), a blank surface has a handful.
    COLORS="$(python3 - "$PNG" <<'PYCOLOR'
import zlib, struct, sys
try:
    from PIL import Image  # optional; the PNG scan below is the portable path
except Exception:
    Image = None
path = sys.argv[1]
data = open(path, "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    print(-1); raise SystemExit
pos = 8
width = height = bitdepth = colortype = 0
idat = b""
while pos + 8 <= len(data):
    (ln,) = struct.unpack(">I", data[pos:pos + 4])
    ctype = data[pos + 4:pos + 8]
    chunk = data[pos + 8:pos + 8 + ln]
    if ctype == b"IHDR":
        width, height, bitdepth, colortype = struct.unpack(">IIBB", chunk[:10])
    elif ctype == b"IDAT":
        idat += chunk
    elif ctype == b"IEND":
        break
    pos += 12 + ln
if bitdepth != 8 or colortype not in (2, 6) or not idat:
    print(-1); raise SystemExit
channels = 3 if colortype == 2 else 4
raw = zlib.decompress(idat)
stride = width * channels
seen = set()
prev = bytearray(stride)
y = 0
i = 0
step_y = max(1, height // 240)
while y < height and i + 1 + stride <= len(raw):
    ftype = raw[i]; i += 1
    line = bytearray(raw[i:i + stride]); i += stride
    if len(line) != stride:
        break
    for x in range(stride):
        a = line[x - channels] if x >= channels else 0
        b = prev[x]
        c = prev[x - channels] if x >= channels else 0
        if ftype == 1:
            line[x] = (line[x] + a) & 0xFF
        elif ftype == 2:
            line[x] = (line[x] + b) & 0xFF
        elif ftype == 3:
            line[x] = (line[x] + ((a + b) >> 1)) & 0xFF
        elif ftype == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xFF
    if y % step_y == 0:
        for x in range(0, stride - channels, channels * 3):
            seen.add((line[x], line[x + 1], line[x + 2]))
            if len(seen) > 4096:
                break
    prev = line
    y += 1
    if len(seen) > 4096:
        break
print(len(seen))
PYCOLOR
)"
    if [ "${COLORS:-0}" -lt 64 ]; then
        echo "❌ frame has only ${COLORS:-0} distinct colours — the window exists but is not rendered"
        exit 1
    fi
    echo "✅ window screenshot: $PNG ($((SZ / 1024)) KB, ${COLORS}+ distinct colours sampled)"
fi
