[简体中文](README.md) ｜ **English**

# ScreenRecorder

A macOS screen recording app for tutorials and meetings. Built from scratch on ScreenCaptureKit, with interaction design modeled on OmniRecorder.

## Features

- **Five capture modes**: fullscreen (per-display) / window / region rubber-band / whole-app (all windows of one application on a fixed canvas) / window region (draw a crop inside a chosen window)
- **Audio mixing**: independent system-audio and microphone toggles; live mic volume slider and in-recording mute
- **Camera PiP**: draggable rounded picture-in-picture; mirrored preview, non-mirrored output (FaceTime-style); auto-degrade and recovery on device unplug/replug
- **Camera virtual background**: person-segmentation backgrounds for the PiP — blur / warm gradient / cool gradient / slate solid, procedurally generated with zero assets; under overload only the newest frame is kept, and segmentation failure falls back to the original picture
- **Click highlighting**: fading yellow ring, toggleable
- **Click auto-zoom**: magnifies at the click point to guide attention (1.35x / 1.6x / 1.9x), recenters on rapid clicks, toggleable
- **Click sound effect**: a soft tick recorded into the take's audio track, toggleable (creates an effects-only track when both audio sources are off)
- **Live markup**: draw on the screen while recording or paused — black/red ink, two widths, undo/clear; annotations burn into the take and stay anchored to content through auto-zoom; `⇧⌘M` toggles the markup toolbar (rebindable)
- **Keystroke visualization**: key presses render as keycaps bottom-center of the take (two colors, three font sizes, adjustable linger); requires Input Monitoring permission, degrades to own-app keys only without it; display pauses automatically while Secure Input (password fields) is detected
- **Pause / resume**: pause durations are excluded from the output timeline
- **Floating control bar**: draggable, non-activating, breathing red dot; discard requires a two-click confirm
- **Global hotkeys**: `⇧⌘R` start/stop (remembers last mode), `⇧⌘P` pause/resume, `⇧⌘W` record a chosen window — rebindable in preferences, no Accessibility permission needed
- **Countdown**: 0 / 3 / 5 / 10 s with an on-screen overlay, cancellable
- **Scheduled recording**: start automatically at a chosen time (or in N minutes) with the last-used mode, with an optional duration cap that stops on time; a missed schedule (sleep) sends a follow-up notification with a "Start recording" action, and busy/locked sessions are skipped with a notice
- **Launch at login**: one-click login item (SMAppService); a failed registration reverts the toggle and notifies
- **Encoding**: H.264 / HEVC (hardware), 30 or 60 fps
- **Interruption protection**: captured window closed or display unplugged → auto-save; recording survives lock; low disk space → auto-finalize the take
- **Quit protection**: quitting mid-recording offers Save & Quit / Discard & Quit / Cancel
- **Recording list**: play, reveal in Finder, rename, delete
- **Menu bar**: state-aware icon (idle/countdown/recording/paused/finishing) with full menu access

## Requirements

- macOS 13.0+
- [Xcode](https://apps.apple.com/app/xcode/id497799835) with command-line tools
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build & Run

```bash
xcodegen generate          # generates ScreenRecorder.xcodeproj (not checked in)
open ScreenRecorder.xcodeproj   # option 1: ⌘R in Xcode
# option 2: command line
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build build
open .build/Build/Products/Debug/ScreenRecorder.app
```

> If `xcode-select` points at the CLT rather than Xcode.app, prefix xcodebuild with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

First use prompts for **Screen Recording / Microphone / Camera** permissions as needed. Global hotkeys use Carbon `RegisterEventHotKey` — no Accessibility permission required.

## Usage Notes

- The app is menu-bar-only (`LSUIElement`); there is no Dock icon
- Recordings land in `~/Movies/ScreenRecorder/录屏_*.mp4` by default; the output directory is configurable
- Window capture: pick a target window once under Preferences → Sources → Window Capture, then `⇧⌘W` starts recording it directly; a stale target prompts re-selection
- For stereo meeting captures, enable both system audio and microphone — output is stereo AAC

## Tests

```bash
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder \
  -configuration Debug -derivedDataPath .build test
```

## Stack

Swift 5 · ScreenCaptureKit (screen + system audio capture) · AVFoundation (mixing, H.264/HEVC writing) · AVCaptureDevice (PiP) · SwiftUI + AppKit (menu bar, floating bar, preferences) · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (global hotkeys) · single `@MainActor` assembly container + capture state machine.

## License

[MIT](LICENSE)
