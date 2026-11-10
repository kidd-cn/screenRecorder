[简体中文](README.md) ｜ **English**

# ScreenRecorder

A macOS screen recording app for tutorials and meetings. Built from scratch on ScreenCaptureKit, with interaction design modeled on OmniRecorder.

## Features

- **Seven capture modes**: fullscreen (per-display) / window / region rubber-band / whole-app (all windows of one application on a fixed canvas) / window region (draw a crop inside a chosen window) / audio-only (.m4a pure audio track) / camera-only (front camera + mixable microphone)
- **Audio mixing**: independent system-audio and microphone toggles; live mic volume slider and in-recording mute
- **Camera PiP**: draggable rounded picture-in-picture; mirrored preview, non-mirrored output (FaceTime-style); auto-degrade and recovery on device unplug/replug
- **Camera virtual background**: person-segmentation backgrounds for the PiP — blur / warm gradient / cool gradient / slate solid, procedurally generated with zero assets; under overload only the newest frame is kept, and segmentation failure falls back to the original picture
- **Mid-recording layout swap**: one tap on the floating bar's ⇄ button swaps the roles (visible while recording/paused in camera-PiP sessions) — the camera becomes the main view (fully contained, never cropped, black bars elsewhere) and the screen shrinks into a 160×120 rounded inset (draggable, the take follows in real time), swap back anytime; each session starts screen-main; while swapped the floating window shows a live screen thumbnail (0.5s refresh) and dragging the window moves the inset; click highlights, markup strokes and auto-zoom still apply to the screen content before it shrinks into the inset, and keycaps stay bottom-center
- **Mouse cursor capture**: the pointer is shown by default, toggleable (snapshot at recording start — changes apply to the next take)
- **Click highlighting**: fading yellow ring, toggleable
- **Click auto-zoom**: magnifies at the click point to guide attention (1.35x / 1.6x / 1.9x), recenters on rapid clicks, toggleable
- **Click sound effect**: a soft tick recorded into the take's audio track, toggleable (creates an effects-only track when both audio sources are off)
- **Live markup**: draw on the screen while recording or paused — strokes render live as you draw, black/red ink, two widths, undo/clear; annotations burn into the take and stay anchored to content through auto-zoom; `⇧⌘M` toggles the markup toolbar (rebindable)
- **Keystroke visualization**: key presses render as keycaps bottom-center of the take (two colors, three font sizes, adjustable linger); requires Input Monitoring permission, degrades to own-app keys only without it; display pauses automatically while Secure Input (password fields) is detected
- **Pause / resume**: pause durations are excluded from the output timeline
- **Floating control bar**: draggable, non-activating, breathing red dot; discard requires a two-click confirm; restart (discards what's recorded and immediately starts over in the same mode — two-click confirm, skips the countdown)
- **Global hotkeys**: `⇧⌘R` start/stop (remembers last mode), `⇧⌘P` pause/resume, `⇧⌘W` record a chosen window — rebindable in preferences, no Accessibility permission needed
- **Countdown**: 0 / 3 / 5 / 10 s with an on-screen overlay, cancellable
- **Scheduled recording**: start automatically at a chosen time (or in N minutes) with the last-used mode, with an optional duration cap that stops on time; a missed schedule (sleep) sends a follow-up notification with a "Start recording" action, and busy/locked sessions are skipped with a notice
- **Screenshots**: a "Screenshots" menu in the menu bar — region rubber-band or full-screen (per-display), saved as PNG to the output directory (`截图_*.png`, never listed among recordings), with a system notification on success
- **Long-recording reminder**: for every full interval of net recording time (pauses excluded) — 1 / 2 / 3 hours, or "never" — one notification fires; each integer multiple reminds exactly once per recording
- **Launch at login**: one-click login item (SMAppService); a failed registration reverts the toggle and notifies
- **Encoding**: H.264 / HEVC (hardware), 30 or 60 fps
- **Interruption protection**: captured window closed or display unplugged → auto-save; recording survives lock; low disk space → auto-finalize the take
- **Camera loss protection**: camera disconnect or stalled frames mid-recording → the recording stops and saves what was captured, with a notification (same semantics as display loss; applies whether or not the layout is swapped)
- **Quit protection**: quitting mid-recording offers Save & Quit / Discard & Quit / Cancel
- **Recording list**: play, reveal in Finder, rename, delete, remove from list (file stays in place)
- **Export**: right-click "Export GIF…" (frame rate / width / loop options) and "Compress…" (H.264/HEVC, 720/1080) with an options sheet + progress; the GIF lands beside the source, the compressed file joins the list
- **Zoom segment editor**: right-click "Edit…" opens a timeline window — video preview + playhead; add/remove segments, drag endpoints, zoom levels 1.35x / 1.6x / 1.9x, nine-grid center placement; export parameters (frame rate / resolution / codec) with a size estimate + progress; segment drafts persist beside the take, the rendered `<原名>_缩放.mp4` joins the list; optional post-export open-in-Finder / delete-original (both off by default)
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
