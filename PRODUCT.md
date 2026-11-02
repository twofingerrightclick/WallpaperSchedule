# Wallpaper Schedule

## Platform
Native macOS app.

## Stack
SwiftUI and AppKit. Swift Package Manager builds a local app bundle without requiring full Xcode.

## Purpose
Let a Mac user select downloaded Apple aerial wallpapers and specify daily times to switch between them. Preserve Apple's native screen saver video and still desktop behavior.

## Constraints
Keep the app very simple. Downloads happen in Apple's System Settings. Use a single daily schedule across displays and Spaces. The settings app exits fully when its window closes. macOS launchd runs a one-shot helper at scheduled times; no GUI or scheduler process remains resident between runs. Local storage only. Apple's aerial selection format is undocumented, so reject unsupported layouts and back up the wallpaper configuration before applying changes.

## Confirmed workflow
Show downloaded aerial thumbnails; select one; choose a time; add, edit, or remove schedule entries. Manual Apply Now supports trying the native switching behavior. launchd handles login/wake catch-up. The settings app is never a login item; it is opened only for configuration.

## Daylight events
The schedule supports fixed clock times and location-based daylight phases: Deep Night (solar midnight), Dawn (civil dawn), Morning (sunrise), Afternoon (solar noon), Evening (one hour before sunset), Sunset, Dusk (civil dusk), and Night (astronomical dusk). Exact phase definitions are implementation defaults, shown in the app. Both opt-in current location and manual coordinates are supported. Calculations happen locally and follow the Mac's current time zone.

## Platform data
Apple's catalog, available downloads, and linked wallpaper configuration are discovered locally. No personal schedule or location is bundled with the app.
