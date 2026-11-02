# Wallpaper Schedule

A small native Mac app that switches between downloaded Apple aerial wallpapers at daily times or local daylight events. Apple's wallpaper system handles the lock-screen video and still desktop frame.

## Run

Build with the macOS Command Line Tools (Swift 6 or later):

```sh
./scripts/build-app.sh
```

For installation and every future update, run:

```sh
./scripts/install-app.sh
```

This builds the latest version, asks the settings app to quit normally, stops old scheduler jobs safely, replaces `/Applications/Wallpaper Schedule.app`, removes the old settings-app login item, and configures macOS scheduling. It leaves the GUI closed. Open the Applications copy from Finder, Spotlight, or the Dock only when you need settings. A per-user instance lock prevents duplicate settings windows/processes. Closing the window quits settings completely.

The installer stages and verifies the new bundle before replacing the old one. It leaves your schedule, location, and wallpaper backups in `~/Library/Application Support/WallpaperSchedule/`. It does not reinstall or reset those preferences. Failed installs restore the previous bundle and scheduler when possible. Quit any much older build without the instance guard before using the installed version.

This is a locally ad-hoc signed build, not a notarized distribution. macOS may request location approval again after a code update; stable Developer ID signing is needed for a distribution with a consistent signing identity.

## Local build identity and private files

The public default bundle identifier is `local.wallpaperschedule`. For an existing custom installation, set `WALLPAPER_BUNDLE_IDENTIFIER` when building, or put its identifier on one line in `.local-bundle-identifier`. That local file is ignored by Git. Keep the identifier stable across updates: the app derives its launchd job labels and single-instance notifications from the bundle.

Only source code, project documentation, tests, and icon artwork belong in the repository. Build output, runtime schedules and coordinates, wallpaper backups, local environment files, and signing keys are ignored. Personal preferences are read from the current user's Library directory at runtime, with no hard-coded home directory.

## Use

1. Download aerials through **System Settings → Wallpaper**. Choose an aerial, enable **Show as Screen Saver**, and enable **Show on all Spaces** when available.
2. Quit System Settings, then refresh the app. It displays downloaded aerial videos with Apple's local names and previews.
3. Select a wallpaper and choose **Fixed Time** or a daylight phase from **When**, then click **Add to Schedule**. Repeat for other wallpapers. Every entry repeats daily; saving applies the currently due wallpaper, including the last entry from a previous day before today's first event.
4. Edit the dropdown or fixed time directly in the schedule. Use the checkbox to skip an entry, the switch to pause everything, or the trash button to remove an entry.

## Daylight scheduling

Set **Daylight Location** using **Use Current Location** (an explicit macOS permission request), or enter latitude/longitude. Coordinates are saved only in the app's local preferences. With current location enabled, the settings app requests a fresh one-shot location when opened, waits up to 30 seconds, and falls back to the saved coordinates if lookup fails. **While settings are closed, scheduling uses the last saved coordinates; it does not track your location.** Open settings to refresh the location after traveling. Manual coordinates stay fixed until you change them. All displayed times use your Mac's current time zone, including daylight-saving changes.

| Dropdown | Meaning |
| --- | --- |
| Deep Night | Solar midnight, when the sun is lowest |
| Dawn | Start of civil twilight, sun rising through −6° |
| Morning | Sunrise |
| Afternoon | Solar noon, when the sun is highest |
| Evening | About one hour before sunset |
| Sunset | Sunset |
| Dusk | End of civil twilight, sun falling through −6° |
| Night | Astronomical night, sun falling through −18° |

The app calculates these approximate times locally using [NOAA's published solar equations](https://gml.noaa.gov/grad/solcalc/solareqns.PDF). It recalculates for each date rather than saving today's clock time. Weather, terrain, and atmospheric refraction can shift observed light. The selected phase shows today's calculated time and its definition. Events absent at polar latitudes are skipped, and catch-up uses the most recent actual event within the preceding year. Fixed and solar rules can be mixed; duplicate phases and duplicate fixed times are rejected. If a fixed and solar event happen at exactly the same second, the solar entry wins deterministically.

**Apply Now** makes a manual choice until the next scheduled occurrence, including across process exits and ordinary coordinate refreshes. Moving to a location or time zone where a different phase or civil day is already active resumes that local schedule.

## No resident background app

macOS `launchd` owns the schedule. There are exactly two stable job labels when active:

- `local.wallpaperschedule.planner`: runs briefly at login and once an hour, recalculates the solar plan, catches up after sleep/time-zone changes, and exits.
- `local.wallpaperschedule.worker`: runs briefly at fixed or calculated event minutes, applies the currently due wallpaper, and exits.

Neither job uses `KeepAlive`; there is no menu bar app or persistent scheduler. The planner replaces the worker definition instead of adding jobs. It plans eight days ahead, rounds solar events up to the next minute, and removes obsolete event times on edit/delete. Pausing or removing all entries unloads both jobs and deletes their generated definitions. The worker rejects expired/date-zone-mismatched plans, preventing dated calendar entries from acting on a stale anniversary next year.

`StartCalendarInterval` coalesces missed events when a sleeping Mac wakes; it does not wake the Mac itself. Login maintenance catches up after shutdown. Hourly maintenance is a bounded fallback for errors and time-zone changes, so those can take up to an hour to recover automatically. A failed occurrence is retried at most three times with at least a minute between attempts; open settings and **Refresh** for an immediate retry. Solar jobs are scheduled for the first minute at or after the calculated event; OS launch latency and the wallpaper action can add delay. The helper records status in `SchedulerStatus.json`, uses an interprocess operation lock, bounds lock/command waits, and exits on every success/failure path (with a final 60-second watchdog for unexpected OS API stalls).

The helper has no SwiftUI or AppKit dependency. It uses Foundation and, only when a change is needed, AVFoundation to validate the local movie before modifying wallpaper settings. The GUI runtime exists only while settings are open. Settings changes are saved locally and immediately reconfigure launchd; the legacy GUI **Start at login** registration is removed during installation.

## Compatibility

The app currently targets Sonoma and Sequoia, with live verification on Sequoia 15.7.7. It intentionally rejects unknown formats, per-display/Space overrides, and wallpaper/screen saver configurations that are not already linked to an aerial. Downloading and playing videos remain macOS responsibilities. No Apple asset files are changed.

There is no documented public API for selecting Apple's native aerials. This app updates the native `Index.plist` selection and restarts the current user's `WallpaperAgent`. It preserves unknown fields, removes automatic shuffle for the shared selection, refuses to apply while System Settings is running, coordinates writes, and checks that the selected asset persisted after reload. **Apple's internal formats can change, and concurrent system writes cannot be made fully transactional with this approach.** The post-reload check confirms configuration selection, not actual lock-screen playback.

The app stores `Schedule.json`, `OriginalWallpaper.plist` (first captured configuration), and `PreviousWallpaper.plist` (last pre-change configuration) in `~/Library/Application Support/WallpaperSchedule/`. These contain local preferences only. To recover, quit the app and choose your preferred aerial again in System Settings. The backups are also ordinary property lists for manual recovery.

## Verify

```sh
./scripts/test.sh
```

Tests use Swift Testing, so full Xcode/XCTest is not required. They cover wallpaper configuration preservation/rejection, catalog discovery, daily/DST boundaries, pause/disabled entries, solar estimates/order, date-line and polar cases, manual overrides, migration, persistence, idempotent event plans and stale-time removal, plan expiry/time-zone guards, lock exclusivity/timeouts, and bounded command failures. Tests use temporary fixtures and do not change the live wallpaper.
