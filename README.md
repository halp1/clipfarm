# ClipFarm

A macOS clipping app for games. It records your screen the whole time it is open and
keeps the recent past in memory. Press a shortcut and the last stretch of it becomes an
MP4, sent wherever you told it to go.

Nothing is written to disk until you press the key, so there is no folder of hour-long
recordings to clean up.

## What it does

- Records the entire screen, always, at the display's native size
- Holds anywhere from 1 second to 5 minutes of it
- Saves to the clipboard, a folder, HALP/CDN, or any combination
- Runs in the background with no window and no Dock tile
- Lives in the menu bar, or nowhere visible at all
- Records system audio, a microphone, both mixed together, or nothing

## Install

```sh
git clone https://github.com/halp1/clipfarm.git
cd clipfarm
Scripts/make-signing-identity.sh   # once, so permissions survive rebuilds
Scripts/build-app.sh --install
```

The first launch asks for screen recording permission. Approve it in System Settings
under Privacy & Security, then Screen & System Audio Recording, and ClipFarm picks it up
within a couple of seconds without needing a restart.

The signing step matters. macOS ties screen recording permission to an app's signature,
and an ad-hoc signature changes on every build, so without a stable certificate you
would have to grant permission again after each one. The script makes a local
self-signed certificate and needs no Apple Developer account.

## Using it

Press ⌘⇧1. The shortcut is configurable in settings.

Open settings from the menu bar icon, or by opening ClipFarm again from Finder while it
is already running.

### Clip length

A slider and a number box, from 1 second to 5 minutes. Both show the same value.

Memory use tracks the length, since ClipFarm holds compressed frames rather than raw
ones. A minute of a 3024x1964 display runs around 45 MB.

### Where clips go

Pick any combination.

Clipboard puts the file itself on the clipboard, so ⌘V works in Finder, Discord,
Messages, or anywhere that takes a file.

Folder keeps a copy in a directory you choose.

HALP/CDN uploads the clip and gives you a link. It needs an API key, which goes in the
field in settings and is stored in your login keychain. Until a key is saved the option
stays switched off.

When the CDN is on and the clipboard is off, the permalink goes to the clipboard
instead of the file. Press the key, then paste a link.

### Audio

Four choices. Output device records the sound going to one specific set of speakers or
headphones, which covers game sound and voice chat. Input device records one microphone
or interface. Both sums them into a single track, adjusted down if they would clip. No
audio makes a silent clip.

Picking the output device by name matters when you have several. Recording "whatever is
the system default" is wrong as soon as you have a virtual device like BlackHole
installed, since the default may be something you never actually listen to. Leave the
choice on the default and ClipFarm follows it, or name a device and it stays there.

Both lists refresh when you open them, and there is a rescan button for a device
plugged in while the window was already open. A device that disappears falls back to
the current default.

macOS asks for microphone permission the first time, even for recording an output
device. A tap can hear anything the machine plays, so it is gated the same way.

## How it works

ScreenCaptureKit streams the display. Frames go straight into one long-lived
VideoToolbox H.264 session, and the compressed samples land in a ring buffer that drops
anything older than the clip length. Because a single encoder session runs the whole
time, samples splice together without a seam.

Keyframes are forced once a second, so a trim never has to reach far back to find one.
When you press the key, AVAssetWriter writes the trailing samples with the video passed
through as it is. Only the audio is encoded at save time.

Audio comes from a Core Audio process tap bound to the chosen device's output stream,
wrapped in a private aggregate device. The tap reports a sample rate that does not
always match what the device runs at, so ClipFarm timestamps the samples using the
device's own rate. Using the tap's figure makes a 44.1 kHz device play back about 9 per
cent fast, which sounds like everything is slightly sharp.

The API key lives in the login keychain under service `dev.haelp.clipfarm`. It is never
written into the repo or the app bundle.

## Triggering it from elsewhere

A Stream Deck, a shell script, or anything that can post a distributed notification:

```sh
osascript -e 'tell application "System Events" to do shell script "true"'  # any host
```

The notification name is `dev.haelp.clipfarm.saveClip`.

## Building

```sh
swift build                  # debug
Scripts/build-app.sh         # ClipFarm.app in dist/
Scripts/build-app.sh --install
```

Debug builds launched from `.build` cannot register the open at login setting, since
`SMAppService` wants a real bundle in /Applications.

## Requirements

macOS 14.2 or later, which is when Core Audio gained the tap API.
