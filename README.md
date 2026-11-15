# <p align="center">![icon_transparent.png](OpenParsec/Assets.xcassets/IconTransparent.imageset/icon_transparent.png) ![OpenParsec](OpenParsec/Assets.xcassets/LogoShadow.imageset/logo_shadow.png)</p>

OpenParsec is a simple, open-source Parsec client for iOS/iPadOS written in Swift using the SwiftUI framework and the Parsec SDK. This project is not affiliated with Parsec.

## Downloads
<p>
<a href="https://stikstore.app/altdirect/?url=https://github.com/hugeBlack/OpenParsec/releases/download/nightly/altstore.json" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200">
</a>
<a href="https://github.com/hugeBlack/OpenParsec/releases/download/nightly/OpenParsec.ipa" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200">
</a>
</p>

These are nightly builds from main. Tagged versions are on the [Releases](https://github.com/hugeBlack/OpenParsec/releases) page.

The .ipa works with AltStore, SideStore, LiveContainer and TrollStore. LiveContainer does not check sources for new builds. For updates, tap install in the source and replace the existing app to get the newest build.

OpenParsec is built against iOS 14 and later.

OpenParsec will never support App Store distribution as it bundles the Parsec SDK, which can't be redistributed under App Store policies.

## Touch Control
There are four touch input modes, the same set Chrome Remote Desktop offers on a phone. Pick one in Settings → Touch Input, from the quick actions button or from the stream menu (Touch Input). Every mode is sent to the PC as mouse, wheel and keyboard input, so it works on any Windows or Mac host.

| | Trackpad | Direct Touch | Two-Finger Pan & Zoom | Three-Finger Pan & Zoom |
| --- | --- | --- | --- | --- |
| Pointer | A cursor you move | Under your finger | Under your finger | Under your finger |
| Tap | Left click at the cursor | Left click where you tap | Left click where you tap | Left click where you tap |
| Double tap | Double click | Double click | Double click | Double click |
| Press and hold | Grey circle, then drag | Right click | Right click | Right click |
| Hold, then drag | Drag | Drag | Drag | Drag |
| 1-finger drag | Move the cursor | Scroll | Scroll | Scroll |
| 2-finger tap | Right click | Right click | Right click | Right click |
| 2-finger drag | Scroll | Scroll | Move the view | Scroll |
| 2-finger pinch | Zoom the view | Zoom in the app (Ctrl + wheel) | Zoom the view | Zoom in the app (Ctrl + wheel) |
| 3-finger drag | Swipe up/down: keyboard | Swipe up/down: keyboard | Swipe up/down: keyboard | Move the view |
| 3-finger pinch | | | | Zoom the view |

Direct Touch always shows the whole desktop. In the other modes, dragging something near the edge of a zoomed view keeps sliding the view so you can reach what's off screen.

Common to all modes:

| Gesture | Action |
| --- | --- |
| 3-finger tap | Middle click (or the keyboard, Settings → Three-Finger Tap) |
| 3-finger swipe up / down | Show / hide the keyboard (opens the stream menu when it's already hidden). Not in Three-Finger Pan & Zoom |
| Swipe in from the left edge | Stream menu, when the buttons are hidden |

In Trackpad mode, Settings → Two-Finger Drag can move the zoomed picture instead of scrolling, and Pinch to Zoom turns view zoom on or off.

The round button in the bottom-right corner opens quick actions: Keyboard, Touch Input, Ctrl+Alt+Del, Start Menu, Resize Desktop to Fit, Fit to Screen (in modes that zoom the view), Stream Menu and Disconnect. It hides with the other buttons and can be turned off in Settings.

Every click shows a short ripple where it landed (blue for right/middle clicks and drags). Click Ripple turns it off.

Pointer Acceleration (on by default) makes slow finger movement precise and fast swipes travel further, like a laptop trackpad. Haptic Feedback gives a small tap on every click, right click and drag. Both can be turned off in Settings.

The keyboard bar has one-tap shortcuts: Copy, Paste, Cut, Undo, Select All, Alt+Tab, Show Desktop, Task Manager, plus Home/End/Page Up/Page Down. With Option Key as Command on (Mac hosts) Copy/Paste/Cut/Undo/Select All use ⌘ instead of Ctrl and Alt+Tab becomes ⌘+Tab; Show Desktop and Task Manager are Windows shortcuts.

## Liquid Glass
On iOS 26 and later OpenParsec uses Apple's Liquid Glass material: the stream menu, menu and keyboard buttons, stats bar, keyboard key bar, hint bubbles, the Touch Input chooser, the main screen's top and bottom bars (the host list scrolls underneath them), and the Connect, Login and Close buttons. Older iOS versions keep the classic flat look. Liquid Glass needs a build made with Xcode 26 or newer, which CI uses.

## Mouse & Keyboard
Hardware mice and keyboards are supported.

Option Key as Command can be turned on in Settings for Mac hosts.

## Game Controllers
One controller is supported. Pressing any trigger during a stream registers it with Parsec. The host needs the virtual USB driver installed.

## Video
Metal is the default renderer, OpenGL can be picked in Settings.

The stream pauses in the background, resumes on return and reconnects after a network drop.

## Troubleshooting
Error codes are explained on Parsec's [error codes page](https://support.parsec.app/hc/en-us/articles/32381281333012-All-Error-Codes).

For "Couldn't reach the host" (-6023) inside LiveContainer, turn on Local Network for LiveContainer in the Settings app.

Microphone passthrough isn't supported by the last public release of the Parsec SDK.

## Lag / Low Bitrate Issue
For sudden lag or a bitrate that hardly goes over 10 Mbps, run Steam Link's network test. Constant spikes in the graph mean a problem with Apple that the app can do little about, see [here](https://github.com/moonlight-stream/moonlight-ios/issues/627) for more discussion.

## Building
Clone with `--recursive` for the Parsec SDK submodule, open `OpenParsec.xcodeproj`, set a team and bundle identifier under Signing & Capabilities, and build. CI builds with the newest stable Xcode (iOS 27 SDK) on the `macos-26` runner.

### Unsigned IPA
The **Build unsigned IPA** workflow (Actions tab → Run workflow) produces `OpenParsec-unsigned.ipa` as a downloadable artifact. Pushing a `v*` tag also attaches it to that release. You can pick the Xcode version, runner image and configuration when starting it by hand.

On a Mac you can build the same file locally:

```bash
./scripts/build-unsigned-ipa.sh
```

The output lands in `build/OpenParsec-unsigned.ipa`. It carries no signature at all, so sign it with AltStore, SideStore, Sideloadly or similar. For TrollStore use the fake-signed nightly instead.

## Contributing
See [CONTRIBUTING](CONTRIBUTING.md).

## License
[GPL-3.0](LICENSE)
