# NotchDrop BuildKit

A native macOS notch-style utility with a configurable set of tabs:

- Music: current track, large album artwork, artist, play/pause, previous and next, a tinted seek bar, and a title that scrolls when it is too long. Click the artwork to open the player.
- Files: temporary drag-and-drop shelf. Drop any number of files in, see real previews, and drag them back out to Finder, upload fields, etc.
- Calendar: upcoming events and quick event creation.
- Alarms: simple alarms with snooze.
- Clipboard: persistent text, URL, file and image history with search, pinning, recopying and drag-out.
- Notes: quick autosaving notes with pinning and search.
- Apps: searchable installed-app launcher with favorites and recent-app ordering.
- Quick Actions: compact Mac actions with confirmation for destructive actions.
- Downloads: active and completed Downloads-folder items with Finder/open/cancel/remove actions.
- Audio: system volume, mute and output-device switching.
- Timer: timer and stopwatch with presets, custom durations, laps and live-notch countdown.
- System: battery, charging, Wi-Fi and Bluetooth status. Moving between the list, the editor and a ringing alarm is animated.

## Settings

Press Command-comma (or use the gear in the notch, or Settings... in the menu bar icon's menu) to open Settings. Command-comma works whenever NotchDrop is the active app (for example with Settings or the menu bar menu open); macOS does not let an app capture it globally without extra permissions.

NotchDrop stays a menu bar app while Settings is open (no Dock icon). Command-W closes the Settings window.

- General: show or hide the menu bar icon, launch at login, which tab to open to, and which tabs are shown.
- Features: clipboard limits/persistence, Notes persistence, Downloads monitoring, timer sound/haptics, System status, and which Quick Actions appear.
- Appearance: notch size (Compact, Regular, Large), accent color, what the closed notch shows, tinting with album art, scrolling titles, seek bar.
- Behavior: open on hover, hover delay, haptics, the key to hold while dragging files, remembering files between launches, and optional global keyboard shortcuts.
- Alarms & Calendar: alarm sound, snooze length, how long an alarm rings, how far ahead the calendar looks, all-day events.

Settings are saved automatically. "Reset All Settings" on the General pane restores the defaults. If you hide the menu bar icon you can still reach Settings from the gear in the notch.

## Requirements

- macOS 13 or newer
- Swift compiler / Xcode Command Line Tools
- Apple Silicon Mac (the supplied build script targets arm64)

## Build and run

Open Terminal and enter:

    cd /path/to/NotchDrop_BuildKit
    chmod +x build.sh
    ./build.sh

The resulting app is:

    build/NotchDrop.app

## Music permissions

The Music tab uses macOS Apple Events to communicate with the Music app. On first use, macOS may ask for permission for NotchDrop to control Music.

If playback controls do not work, check:

System Settings -> Privacy & Security -> Automation

and allow NotchDrop to control Music.

## Utility tabs

Clipboard, Notes, Apps, Quick Actions, Downloads, Audio, Timer and System are optional tabs. The tab visibility controls in Settings decide which appear. Files also includes Shelf, Recent and Folders views, with built-in Downloads/Desktop/Documents/Applications shortcuts and custom folder shortcuts.

The global search button in the notch searches NotchDrop-owned files, clipboard entries, notes, apps, calendar events and alarms.

Global shortcuts are optional. When enabled, ⌘⇧Space opens the notch, ⌘⇧1–4 select Music/Files/Calendar/Alarms, ⌘⇧5 selects Clipboard, and ⌘⇧T selects Timer. macOS can require Input Monitoring/Accessibility permission for global key monitoring.

## File shelf

Hold Control (or the key you chose in Settings) while dragging files toward the top of the screen, then drop them on the notch. Dropping several files at once adds them all; the newest are shown first and duplicates are ignored.

- Drag a file tile out to Finder, a browser upload field, a message, etc.
- Files, folders, images, text and URLs can be dropped into the notch. Text and web URLs are added to the Clipboard workflow rather than the file shelf.
- Hover a tile and click the x to remove it.
- Double-click a tile to open the file. Right-click for Open, Show in Finder, Copy and Remove.
- Clear (top right of the Files tab) empties the shelf.

Files are not copied anywhere. The app keeps references to the originals, and quietly drops any that were moved or deleted. By default the list is temporary and is cleared when the app quits; turn on "Remember files between launches" in Settings to keep it.

## Live activities

Temporary activity information uses the existing closed-notch/live-activity system. Priority is alarm, timer, download, music, calendar countdown, charging status, then the file shelf. The collapsed notch remains compact when there is nothing useful to show.

## Notes

The window is a borderless floating panel anchored to the top-center of the main screen. Click the compact notch to expand it.

The build is intentionally self-contained and uses an `@main` application entry point with no executable top-level statements. SwiftUI's macro-dependent `@State` wrappers have also been avoided so the direct `swiftc` build does not depend on a missing SwiftUI macro plugin.


## Notch behavior

On Macs with a notch the closed panel matches the real notch size, and the open panel keeps its tab buttons on either side of it. Other Macs get a small pill at the top center.

Rest the pointer on the notch for a moment to open it (a quick sweep across the top of the screen will not). Moving the pointer away closes it again; the pin button keeps it open.

The closed notch is always the same width, whether music is playing, paused or absent, so it never jumps. While music is playing it shows the album art on the left and moving bars on the right; when music stops or pauses that crossfades to a tray icon and file count (if files are waiting) or to nothing.
