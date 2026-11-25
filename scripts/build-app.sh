#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p .build/module-cache dist
export CLANG_MODULE_CACHE_PATH="$root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/module-cache"
build_args=(--disable-sandbox --build-system native -c release)
swift build "${build_args[@]}"
binary="$(swift build "${build_args[@]}" --show-bin-path)/TunnelMenu"
bundle=dist/TunnelMenu.app
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$binary" "$bundle/Contents/MacOS/TunnelMenu"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TunnelMenu</string>
    <key>CFBundleDisplayName</key><string>TunnelMenu</string>
    <key>CFBundleExecutable</key><string>TunnelMenu</string>
    <key>CFBundleIdentifier</key><string>com.x1angyulu.TunnelMenu</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
printf '%s/%s\n' "$root" "$bundle"
