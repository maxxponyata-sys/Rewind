<p align="center"><img src="icon-1024.png" width="128" alt="Rewind icon"></p>

# Rewind

**A lightweight YouTube client for iOS 10.3.x — built for the iPhone 5, 5c, 5s, 6 and the iPads of that era.**

The official YouTube app dropped iOS 10 long ago. Rewind brings back browsing and watching on old devices, using an [Invidious](https://invidious.io) server for the data and streams.

## Features

- **Trending** for your region (falls back to Popular when the server has no trending list)
- **Search** for videos and channels with infinite scroll
- **Channels**: browse uploads and **subscribe without an account**. Subscriptions are stored on the device and the **Subscriptions** tab merges their newest videos.
- **Player** with native iOS controls, quality from 240p to 1080p, related videos and description
- **Audio-only mode** and **background playback** with lock-screen and Control Center controls (play/pause, skip ±15 s)
- **Library**: saved videos, watch history, subscribed channels (swipe a row to save or remove it)
- Runs on **32-bit (armv7) and 64-bit (arm64)** devices, iPhone and iPad, iOS 10.0 – 10.3.4
- Works with servers that use modern Let's Encrypt certificates. iOS 10 doesn't trust those out of the box, so Rewind ships the ISRG root certificates and checks connections against them itself.

## Install

Download the files from the [latest release](https://github.com/maxxponyata-sys/Rewind/releases/latest).

| Your device | File | How |
|---|---|---|
| Jailbroken (h3lix, doubleH3lix, Meridian…) | `Rewind-1.0.0-iphoneos-arm.deb` | Install it with Filza or `dpkg -i`, then respring if the icon doesn't show up |
| Jailbroken with AppSync Unified | `Rewind-1.0.0.ipa` | Install it with Filza, ReProvision or AppSync |
| Not jailbroken | `Rewind-1.0.0.ipa` | Sideload it with [Sideloadly](https://sideloadly.io) or another sideloading tool and your Apple ID (free accounts have to re-sign every 7 days) |

The IPA is only fake-signed with ldid; sideloading tools re-sign it with your own certificate.

## Servers

Rewind's default server is `https://yt.chocolatemoo53.com`, a public Invidious server run by a third party. It's not affiliated with Rewind and can change or go offline at any time.

Public Invidious servers come and go, and many block apps. If videos stop loading:

1. Open **Settings → Invidious server**, enter another server address and tap **Test connection**.
2. Or [host your own](https://docs.invidious.io/installation/) (with invidious-companion). It's the most reliable option.

The server needs to have its API enabled and to proxy video streams (`local=true`), since YouTube stream links only work for the server's IP address.

## How playback works

YouTube now serves picture and sound as separate streams (the old combined 360p/720p MP4s are mostly gone). Rewind picks the best H.264 video stream at or below your quality setting plus the AAC audio stream, then plays them together with `AVMutableComposition`. Every byte goes through a custom `AVAssetResourceLoader`, so streams play even from servers with modern certificates.

## Building

Rewind is plain Objective-C (UIKit + AVFoundation, no dependencies) built with [Theos](https://theos.dev).

```bash
export THEOS=~/theos
python3 tools/make_art.py          # icons and launch images (needs Pillow)
make package FINALPACKAGE=1        # .deb in packages/
```

You need an iOS 10.3 SDK whose `.tbd` stubs include the armv7 symbols. The SDK in `theos/sdks` lacks them, so use the one from `xybp888/iOS-SDKs`. If arm64 then fails to link on `__Unwind_Resume`, add the arm64 zero-cost unwind symbols to `usr/lib/system/libunwind.tbd`.

To make an IPA, put `.theos/obj/Rewind.app` in a `Payload/` folder and zip it.

## Status

Version 1.0.0 is the first release. It builds cleanly for armv7 and arm64, and the server API it relies on was tested from a PC. **It hasn't been tested on a real iOS 10 device yet.** Please [open an issue](https://github.com/maxxponyata-sys/Rewind/issues) with your device model and iOS version if something doesn't work.

## Disclaimer

Rewind is an unofficial client. It's not affiliated with, endorsed by or connected to YouTube or Google. "YouTube" is a trademark of Google LLC. Rewind doesn't host or download any content; it only shows what the Invidious server you choose provides.

## License

[MIT](LICENSE)
