# ClipFarm build plan

## What it does

ClipFarm keeps the last N seconds of your screen in memory. Press the hotkey and it
writes that window to an MP4 and sends it wherever you told it to go.

## Shape of the app

A SwiftPM executable assembled into `ClipFarm.app`, ad-hoc signed, installed to
`/Applications`. `LSUIElement` is true, so there is no Dock tile and no window at
launch. The app lives in the menu bar and the settings window opens on demand.

## Capture

ScreenCaptureKit streams the full display. Frames go through a single
`VTCompressionSession` (H.264, one keyframe per second, no frame reordering) and the
encoded samples land in a ring buffer trimmed to the configured duration plus a few
seconds of slack. System audio rides along as PCM in a second ring and gets encoded to
AAC only when a clip is written.

One continuous encoder session means no seams in the output. Trimming starts at the
last keyframe at or before the target start time.

## Saving

On trigger, `AVAssetWriter` writes the trailing N seconds: video passed through
without re-encoding, audio encoded to AAC. The file goes to the destinations that are
switched on.

- Clipboard: the file URL, so it pastes into Finder, Discord, Messages.
- Folder: a copy in the configured directory.
- HALP/CDN: upload, then the permalink.

When CDN is on and clipboard is off, the permalink goes to the clipboard instead of
the file.

## The API key

The key lives in the login keychain under service `dev.haelp.clipfarm`. It is never
written to the repo. The CDN destination stays disabled and unselectable until a key
is present, and the settings window has a field to paste one in.

## Settings

- Clip duration from 1 second to 5 minutes, slider and number box, kept in sync
- Hotkey, recorded by pressing the combination, default command shift 1
- Open at login through `SMAppService`
- Menu bar icon on or off
- Destination toggles and the folder picker

## Order of work

1. Repo, package skeleton, first commit
2. Preferences, keychain, hotkey
3. Capture engine and ring buffer
4. Clip export
5. Destinations
6. Menu bar and settings UI
7. Bundle script, build, install to /Applications
8. Verify a real clip through every destination
9. README, push to github.com/halp1/clipfarm
