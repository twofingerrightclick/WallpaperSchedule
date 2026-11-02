#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
APP_IDENTIFIER="${WALLPAPER_BUNDLE_IDENTIFIER:-}"
if [[ -z "$APP_IDENTIFIER" && -f .local-bundle-identifier ]]; then
    IFS= read -r APP_IDENTIFIER < .local-bundle-identifier
fi
APP_IDENTIFIER="${APP_IDENTIFIER:-local.wallpaperschedule}"
if [[ ! "$APP_IDENTIFIER" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]]; then
    print -u2 -- "Invalid app bundle identifier. Use letters, numbers, periods, and hyphens."
    exit 1
fi
swift build -c release --scratch-path .build --disable-sandbox
APP="$PWD/build/Wallpaper Schedule.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
./scripts/build-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/WallpaperSchedule "$APP/Contents/MacOS/WallpaperSchedule.next"
mv -f "$APP/Contents/MacOS/WallpaperSchedule.next" "$APP/Contents/MacOS/WallpaperSchedule"
cp .build/release/WallpaperScheduler "$APP/Contents/Helpers/WallpaperScheduler.next"
mv -f "$APP/Contents/Helpers/WallpaperScheduler.next" "$APP/Contents/Helpers/WallpaperScheduler"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.wallpaperschedule</string>
<key>CFBundleName</key><string>Wallpaper Schedule</string>
<key>CFBundleDisplayName</key><string>Wallpaper Schedule</string>
<key>CFBundleExecutable</key><string>WallpaperSchedule</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.1</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSLocationUsageDescription</key><string>Use your location to calculate daily dawn, sunset, and other daylight wallpaper changes. Coordinates are stored only on this Mac.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Use your location to calculate daily dawn, sunset, and other daylight wallpaper changes. Coordinates are stored only on this Mac.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_IDENTIFIER" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/Helpers/WallpaperScheduler"
codesign --force --sign - "$APP"
print -r -- "$APP"
