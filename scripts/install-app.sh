#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" == "--skip-build" ]]; then
    shift
else
    ./scripts/build-app.sh
fi
if (( $# > 0 )); then
    print -u2 -- "Usage: ./scripts/install-app.sh [--skip-build]"
    exit 1
fi

SOURCE="$PWD/build/Wallpaper Schedule.app"
INSTALL_DIRECTORY="${WALLPAPER_INSTALL_DIRECTORY:-/Applications}"
DESTINATION="$INSTALL_DIRECTORY/Wallpaper Schedule.app"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
if [[ "$INSTALL_DIRECTORY" != /* || ! -d "$INSTALL_DIRECTORY" || -L "$DESTINATION" ]]; then
    print -u2 -- "Choose an existing absolute Applications directory; the app destination must not be a symlink."
    exit 1
fi
if [[ ! "$IDENTIFIER" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*$' ]]; then
    print -u2 -- "The built app has an unexpected identity."
    exit 1
fi
codesign --verify --deep --strict "$SOURCE"
if [[ -e "$DESTINATION" && "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DESTINATION/Contents/Info.plist")" != "$IDENTIFIER" ]]; then
    print -u2 -- "A different application already exists at $DESTINATION. It was left unchanged."
    exit 1
fi

STAGING="$(mktemp -d "$INSTALL_DIRECTORY/.WallpaperSchedule-install.XXXXXX")"
REPLACED=0
REOPEN_ON_FAILURE=0
SCHEDULER_STOPPED=0
COMMITTED=0
cleanup() {
    local result=$?
    if (( COMMITTED )); then rm -rf "$STAGING"; return; fi
    if (( result != 0 && REPLACED )) && [[ -x "$DESTINATION/Contents/Helpers/WallpaperScheduler" ]]; then
        if ! "$DESTINATION/Contents/Helpers/WallpaperScheduler" stop; then
            print -u2 -- "Could not stop the new scheduler for rollback. Both app versions are preserved at $DESTINATION and $STAGING."
            return
        fi
    fi
    if (( result != 0 && REPLACED )) && [[ -e "$DESTINATION" ]]; then
        if ! mv "$DESTINATION" "$STAGING/Rejected.app"; then
            print -u2 -- "Update failed. App bundles are preserved at $DESTINATION and $STAGING"
            return
        fi
    fi
    if (( result != 0 )) && [[ -d "$STAGING/Previous.app" && ! -e "$DESTINATION" ]]; then
        if ! mv "$STAGING/Previous.app" "$DESTINATION"; then
            print -u2 -- "Restore failed. The previous app is preserved at $STAGING/Previous.app"
            return
        fi
    fi
    if (( result != 0 && SCHEDULER_STOPPED )) && [[ -x "$DESTINATION/Contents/Helpers/WallpaperScheduler" ]]; then
        "$DESTINATION/Contents/Helpers/WallpaperScheduler" configure || print -u2 -- "Open Wallpaper Schedule and Refresh to restore macOS scheduling."
    fi
    if (( result != 0 && REOPEN_ON_FAILURE )); then
        local reopen_path="$SOURCE"
        if [[ -d "$DESTINATION" ]]; then reopen_path="$DESTINATION"; fi
        .build/AppLifecycle open "$reopen_path" || print -u2 -- "Reopen Wallpaper Schedule manually to resume scheduling."
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
ditto "$SOURCE" "$STAGING/Wallpaper Schedule.app"
codesign --verify --deep --strict "$STAGING/Wallpaper Schedule.app"
swiftc -parse-as-library -module-cache-path "$PWD/.build/module-cache" scripts/AppLifecycle.swift -o .build/AppLifecycle
PRIOR_STATE="$(.build/AppLifecycle status "$IDENTIFIER")"
if [[ "$PRIOR_STATE" == "running" ]]; then REOPEN_ON_FAILURE=1; fi
# Keep quit outside a conditional: errexit must stop the update on refusal/timeout.
.build/AppLifecycle quit "$IDENTIFIER" >/dev/null
if [[ -x "$DESTINATION/Contents/Helpers/WallpaperScheduler" ]]; then
    "$DESTINATION/Contents/Helpers/WallpaperScheduler" stop
    SCHEDULER_STOPPED=1
fi

if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGING/Previous.app"; fi
mv "$STAGING/Wallpaper Schedule.app" "$DESTINATION"
REPLACED=1
codesign --verify --deep --strict "$DESTINATION"
"$DESTINATION/Contents/Helpers/WallpaperScheduler" configure
# Commit legacy login removal only after the headless replacement works. Rollback
# before this point leaves the previous app's login registration untouched.
"$DESTINATION/Contents/MacOS/WallpaperSchedule" --disable-legacy-login
COMMITTED=1
print -r -- "Installed: $DESTINATION"
print -r -- "macOS now runs the schedule without a resident app. Open this Applications copy only to edit settings."
