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

Recording starts off. Click the menu bar icon to start, and it turns red while
recording. Click it again to stop. Right click for the menu: start or stop, save a clip,
settings, quit.

Press ⌘⇧1 to save the last stretch of what was recorded. The shortcut is configurable
in settings.

Nothing is captured while recording is off, so ClipFarm costs nothing until you switch
it on. That also means the screen recording indicator only appears while you are
actually recording. macOS draws that indicator and no app can hide it.

Open settings by right clicking the menu bar icon, or by opening ClipFarm again from
Finder while it is already running. ⌘W closes the window and ⌘Q quits.

### Clip length

A slider and a number box, from 1 second to 5 minutes. Both show the same value.

Memory use tracks the length, since ClipFarm holds compressed frames rather than raw
ones. A minute at the default resolution runs around 140 MB.

### Quality

Frame rate and resolution are settings, defaulting to 1080p at 30 fps. Resolution runs
from your display's native size down to 360p, each option labelled with the size it
actually records: the width follows your display's shape, so on a 3024 by 1964 panel
the 1080p option records 1662 by 1080 rather than 1920 by 1080.

These decide how much battery ClipFarm costs while recording. On this machine native at
60 fps ran about 6 per cent CPU and the default runs about 3. Idle costs nothing.

Memory follows the same numbers, since the buffer holds encoded frames. A 30 second
buffer at the default runs around 70 MB.

### Where clips go

Pick any combination.

Clipboard puts the file itself on the clipboard, so ⌘V works in Finder, Discord,
Messages, or anywhere that takes a file.

Folder keeps a copy in a directory you choose.

HALP/CDN uploads the clip and gives you a link. It needs an API key, which goes in the
field in settings and is stored in your login keychain. Until a key is saved the option
stays switched off.

The folder field sets where uploads land, `clips` by default. Nested folders work, so
`clips/apex` or `gameplay/2026/sep` are both fine, and the line under the field shows
the resulting link. Slashes, spaces and dot segments get cleaned up, so pasting
`/clips/apex/` gives the same result as typing `clips/apex`.

Clips always go in a folder. An empty field falls back to `clips`, because the CDN
stores a top level upload under a key beginning with a slash and its public route
cannot address those, so the upload would succeed and the link would 404.

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

ClipFarm reads the key once per launch and keeps it in memory, and it rewrites the
keychain item on first run so the item belongs to the app. Both matter for how often
macOS asks permission: a keychain item keeps the access list of whatever process
created it, so an item added by another tool prompts on every read, and every separate
read is its own prompt.

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
