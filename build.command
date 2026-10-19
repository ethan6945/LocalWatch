#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/LocalWatch.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# macOS 27 SDK 把 SwiftUI 的 @State 改成了宏，宏插件只随完整 Xcode 提供。
# 只装 Command Line Tools 的机器上自动退回仍可直接编译的 SDK。
SDK_ROOT="$(xcode-select -p)/SDKs"
SDK_PATH="$(xcrun --show-sdk-path)"
if grep -q 'macro State' "$SDK_PATH/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface" 2>/dev/null; then
  for candidate in "$SDK_ROOT"/MacOSX*.sdk; do
    if ! grep -q 'macro State' "$candidate/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface" 2>/dev/null; then
      SDK_PATH="$candidate"
    fi
  done
  echo "使用 SDK: $SDK_PATH"
fi

swiftc -O -parse-as-library -target arm64-apple-macosx26.0 -sdk "$SDK_PATH" Source/Monitor.swift Source/App.swift -o "$APP/Contents/MacOS/LocalWatch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LocalWatch</string>
<key>CFBundleIdentifier</key><string>local.ethan.LocalWatch</string>
<key>CFBundleName</key><string>LocalWatch</string>
<key>CFBundleDisplayName</key><string>LocalWatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
cp Source/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
