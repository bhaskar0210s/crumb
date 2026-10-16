<p align="center"><img src="docs/icon.png" width="128" alt="Crumb"></p>

<h1 align="center">Crumb</h1>

<p align="center"><b>A tiny clipboard history for your Mac.</b><br>
Press <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> anywhere to see everything you copied: text, pictures and files.<br>
About 500 KB on disk, 7 MB of memory at launch and 9 to 12 MB after use, no CPU while idle.</p>

<p align="center">
  <img src="docs/popup-dark.png" width="430" alt="Crumb's list in dark mode">
  <img src="docs/popup-light.png" width="430" alt="Crumb's list in light mode">
</p>

## What it does

- **Opens at the pointer** with <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> (pick any shortcut in Settings). It appears and
  disappears instantly, with no animations.
- **⌘1 to ⌘9** copy one of the first nine entries. <kbd>↑</kbd> <kbd>↓</kbd> and <kbd>Return</kbd>, or a click,
  copy any of them. <kbd>Esc</kbd> closes the list and <kbd>⌥</kbd><kbd>⌫</kbd> deletes the selected entry.
- **Just type to search.** The search field appears as you type. Search is fuzzy: type a few letters in order
  (`gcm` finds `git commit -m`) and the matched letters are shown in bold.
- **Hover over an entry, or select it, for three seconds** to see the whole text or the full-size picture.
- **Keeps everything you copy, in full**: text of any length (with its formatting), pictures and files, newest
  first. Copying something again moves it back to the top.
- **Clear History** sits at the bottom of the list, next to the gear that opens the settings.

<p align="center">
  <img src="docs/search-dark.png" width="430" alt="Fuzzy search with matched letters in bold">
  <img src="docs/settings-dark.png" width="430" alt="Settings">
</p>

The settings open right inside the list and hold only what you need: the shortcut, launch at login, automatic
updates and how many entries to keep (100 by default).

## Private by design

- Your history never leaves your Mac. It lives in `~/Library/Application Support/Crumb`, a few small files per
  entry, and only your user account can read it.
- Passwords stay out. Password managers mark what they copy as concealed or transient (see
  [nspasteboard.org](http://nspasteboard.org)), and Crumb never saves it.
- The only connection Crumb makes is a daily check of this repository's releases, and you can turn that off in
  Settings. Updates are signed: Crumb installs a new version only if its download carries a valid signature
  from the project's release key.
- No accounts, no telemetry, no ads. Crumb is free and open source under the MIT License.

## Install

Crumb runs on Macs with Apple silicon, on macOS 27 or later. Install it with Homebrew:

```sh
brew install bhaskar0210s/tap/crumb
```

Or without Homebrew, with one command in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/bhaskar0210s/crumb/main/install.sh | sh
```

It downloads the latest release, checks it against the signature of Crumb's release key, installs it in Applications
and opens it. Both ways, Crumb opens right away.

**Or download it:** get `Crumb.dmg` from the [latest release](../../releases/latest), open it and drag Crumb to
Applications. macOS checks apps downloaded in a browser with Apple, and Crumb isn't notarized (that needs a paid
Apple developer account), so the first time you open it macOS says it can't verify that Crumb is free of malware.
Choose **Done**, then open System Settings → Privacy & Security and click **Open Anyway** next to Crumb. You only
need to do this once.

macOS also asks before an app reads what you copied in other apps. Allow Crumb, or turn it on in System Settings →
Privacy & Security → Paste from Other Apps. If macOS still asks or refuses, Crumb's settings say so.

**Or build it yourself** with the Xcode command line tools (`xcode-select --install`):

```sh
git clone https://github.com/bhaskar0210s/crumb.git
cd crumb
make install    # builds Crumb.app, copies it to /Applications and starts it
```

The first launch from Applications adds Crumb to your login items and shows its settings once. Crumb has no
Dock icon and no menu bar icon: press the shortcut to use it, and use the gear in the list (or open the app again
from Spotlight) for its settings.

## How it stays small

- **Native code only.** Swift and AppKit, with Core Text and Core Graphics drawing everything. No SwiftUI, no web
  views, no third-party libraries.
- **No system text fields.** The search box is drawn by Crumb, which reads the keyboard itself. A standard text
  field would load macOS's whole text engine and make the system start an AutoFill helper process (about 13 MB)
  just for Crumb. Input methods (Chinese, Japanese, Korean…) still work: Crumb asks for the text input system
  only while one of them is the current input source.
- **Drawn on the CPU, into shared memory.** Every view renders into an IOSurface that the window server composites
  straight from, so the pixels exist once. A plain image would be copied for the window server, and the system's
  default path moves larger views onto the GPU, which loads a couple of megabytes of shaders that never go away.
  Pictures sit on layers of their own, in their own color profile, and the window server matches them to the
  display.
- **One color space for every window.** Left to the display's color profile, AppKit and Core Animation convert
  through a new ColorSync transform for each window and keep its 272 KB lookup table: one more every time the list
  or a preview opens, which added up to 13 MB in an earlier version. Crumb's windows use sRGB, which it draws in
  anyway.
- **Nothing is kept while the list is closed.** Its window is built when you press the shortcut (in about 10 ms)
  and torn down when it closes. Settings live inside the same panel instead of a window of their own. A preview
  lets go of its decoded picture as soon as it is drawn.
- **Copies don't linger.** Crumb reads each copy through a pasteboard reference of its own and lets go of it once
  the copy is read. Reading through AppKit's pasteboard would keep the last copy in memory until the next one:
  20 MB after copying a screenshot. Pictures that arrive as TIFF, as many apps copy them, become PNG straight from
  the source, without decoding the whole picture first.
- **Only a little lives in memory.** Each entry keeps its first few kilobytes in memory for drawing and searching;
  full texts and pictures stay on disk until you preview or copy them. Pictures are shrunk once into small
  thumbnails for the list, and previews lay out only the paragraphs in view.
- **Cheap watching.** macOS doesn't announce copies, so Crumb reads the pasteboard's change count twice a
  second, which costs next to nothing.

Measured with `footprint` (the number Activity Monitor shows) on an Apple silicon Mac running macOS 27, with a full
history of 100 entries that includes pictures in six different color profiles: about 7 MB right after launch,
14 MB while the list is open (up to about 20 MB with a full-size preview or a search running) and 9 to 12 MB once
it has closed, flat over a 30-minute soak, with no helper processes. The list opens in about 10 ms (40 ms the
first time after launch). Copying a 20 MB picture peaks at about 50 MB while it is saved, then memory returns to
where it was. CPU use while idle is 0.0%.

## Tested

- `make test` runs the core's unit tests (history storage, fuzzy search, text handling and version checks) with
  AddressSanitizer.
- `leaks` finds nothing from Crumb after a session of opens, searches, previews and copies, or after a 30-minute
  soak. It does report a small cycle inside Apple's AppIntents framework that every AppKit app gets on macOS 27.
- A 30-minute soak (an open with a preview every 30 seconds, searches, and copies of text and screenshots) stays
  flat at about 12 MB.
- Stress tests cover a 53 MB text, an 8K picture and copies made back to back. Every byte is kept.
- Installing, upgrading and uninstalling with Homebrew print no warnings, and the installed app opens without a
  prompt.

## Development

```sh
make              # build/Crumb.app
make dmg          # build/Crumb.dmg
make run          # build and start it from build/
make test         # unit tests
make icon         # redraw resources/Crumb.icns
```

`Sources/Core` holds the history store and the fuzzy search, and `Sources/App` the AppKit side. Pushing a tag such
as `v2.0.1` builds Crumb on GitHub, signs it, publishes a release with `Crumb.dmg` and `Crumb.zip`, and updates the
cask in [bhaskar0210s/homebrew-tap](https://github.com/bhaskar0210s/homebrew-tap). Installed copies with
automatic updates turned on install it within a day.

Releases are signed with an ECDSA P-256 key kept in the repository secret `UPDATE_SIGNING_KEY` (PEM). Its public
half is `CrumbUpdateKey` in `resources/Info.plist`, and also sits in `install.sh`. A fork that publishes its own
releases needs its own key pair:

```sh
openssl ecparam -name prime256v1 -genkey -noout -out update-key.pem             # keep this private
openssl ec -in update-key.pem -pubout -outform DER | tail -c 65 | base64        # goes into Info.plist
openssl ec -in update-key.pem -pubout                                           # goes into install.sh
```

## License

[MIT](LICENSE)
