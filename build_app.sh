#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DriveOffloader"
BUNDLE_DIR="${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

swift build -c release

rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Generate macOS AppIcon.icns via CoreGraphics/AppKit + sips + iconutil
ICON_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${ICON_TMP_DIR}"' EXIT
BASE_PNG="${ICON_TMP_DIR}/icon_1024.png"
ICONSET_DIR="${ICON_TMP_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

swift - "${BASE_PNG}" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext

// Outer macOS squircle background
let margin: CGFloat = 82
let rect = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 196, yRadius: 196)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.16, alpha: 1.0).setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()

let bgColors = [
    NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.21, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1.0).cgColor
] as CFArray
let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 512, y: 942), end: CGPoint(x: 512, y: 82), options: [])

// Subtle top glow
let glowColors = [
    NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.92, alpha: 0.24).cgColor,
    NSColor(calibratedRed: 0.15, green: 0.72, blue: 0.92, alpha: 0.0).cgColor
] as CFArray
let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: 512, y: 720), startRadius: 10, endCenter: CGPoint(x: 512, y: 720), endRadius: 420, options: [])

// Drive platter / thermal bars at bottom
let barColors: [NSColor] = [
    NSColor(calibratedRed: 0.06, green: 0.80, blue: 0.56, alpha: 1.0),
    NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.16, alpha: 1.0),
    NSColor(calibratedRed: 0.96, green: 0.40, blue: 0.24, alpha: 1.0),
    NSColor(calibratedRed: 0.84, green: 0.12, blue: 0.60, alpha: 1.0)
]

let driveBox = CGRect(x: 222, y: 205, width: 580, height: 220)
let drivePath = NSBezierPath(roundedRect: driveBox, xRadius: 44, yRadius: 44)
NSColor(calibratedRed: 0.14, green: 0.18, blue: 0.28, alpha: 0.95).setFill()
drivePath.fill()
NSColor.white.withAlphaComponent(0.16).setStroke()
drivePath.lineWidth = 4
drivePath.stroke()

// Thermal gradient strip inside drive
let stripWidth: CGFloat = 112
let startX: CGFloat = 258
for (idx, col) in barColors.enumerated() {
    let bx = startX + CGFloat(idx) * (stripWidth + 20)
    let bRect = CGRect(x: bx, y: 245, width: stripWidth, height: 34)
    let bPath = NSBezierPath(roundedRect: bRect, xRadius: 12, yRadius: 12)
    col.setFill()
    bPath.fill()
}

// Drive slot & LED
let slotRect = CGRect(x: 258, y: 315, width: 390, height: 24)
NSColor.white.withAlphaComponent(0.14).setFill()
NSBezierPath(roundedRect: slotRect, xRadius: 12, yRadius: 12).fill()

let ledRect = CGRect(x: 724, y: 313, width: 28, height: 28)
NSColor(calibratedRed: 0.08, green: 0.92, blue: 0.68, alpha: 1.0).setFill()
NSBezierPath(ovalIn: ledRect).fill()

// Cloud / Offload arrow symbol in upper half
let arrowColor = NSColor(calibratedRed: 0.22, green: 0.86, blue: 0.98, alpha: 1.0)
let cloudColor = NSColor.white.withAlphaComponent(0.95)

// Stylized cloud silhouette
let cloud = NSBezierPath()
cloud.appendOval(in: CGRect(x: 270, y: 550, width: 200, height: 180))
cloud.appendOval(in: CGRect(x: 375, y: 600, width: 270, height: 240))
cloud.appendOval(in: CGRect(x: 545, y: 545, width: 210, height: 185))
cloud.appendRect(CGRect(x: 365, y: 545, width: 295, height: 125))
cloudColor.setFill()
cloud.fill()

// Upward offload arrow cutting cleanly over drive -> cloud
ctx.saveGState()
let arrow = NSBezierPath()
let cx: CGFloat = 512
arrow.move(to: CGPoint(x: cx, y: 695))
arrow.line(to: CGPoint(x: cx + 92, y: 585))
arrow.line(to: CGPoint(x: cx + 38, y: 585))
arrow.line(to: CGPoint(x: cx + 38, y: 405))
arrow.line(to: CGPoint(x: cx - 38, y: 405))
arrow.line(to: CGPoint(x: cx - 38, y: 585))
arrow.line(to: CGPoint(x: cx - 92, y: 585))
arrow.close()

ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.35).cgColor)
arrowColor.setFill()
arrow.fill()
ctx.restoreGState()

ctx.restoreGState()

// Squircle inner border
NSColor.white.withAlphaComponent(0.18).setStroke()
squircle.lineWidth = 5
squircle.stroke()

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
try pngData.write(to: URL(fileURLWithPath: outPath))
SWIFT

for sz in 16 32 128 256 512; do
    sips -z "${sz}" "${sz}" "${BASE_PNG}" --out "${ICONSET_DIR}/icon_${sz}x${sz}.png" >/dev/null
    sz2=$((sz * 2))
    sips -z "${sz2}" "${sz2}" "${BASE_PNG}" --out "${ICONSET_DIR}/icon_${sz}x${sz}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DriveOffloader</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.driveoffloader.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DriveOffloader</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "${BUNDLE_DIR}"
touch "${BUNDLE_DIR}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -f "${BUNDLE_DIR}" || true
fi
echo "Built and signed ${BUNDLE_DIR}"
