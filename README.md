# iPhone 5 Generator

A small Mac app that gives video the picture and sound of an iPhone 5 concert recording. Drop in a file, wait for it to render, and choose where to save it.

## Using the app

1. Open **iPhone 5 Generator.app**.
2. Drag a video into the window, or click **Open…** (`⌘O`).
3. Follow the rendering progress bar. **Cancel** stops the conversion.
4. Choose a filename and location in the macOS Save dialog.

After saving, the app is ready for another video. Canceling the Save dialog discards the rendered copy. If saving fails, you can choose another location without converting again.

Everything runs locally. Your original file is never modified.

Progress follows FFmpeg's actual encoded-frame count against the video's
reported duration. The app shows **Finalizing…** while finishing the movie
file and reports completion only after FFmpeg exits successfully. Clips
without a usable duration show a spinner and a rendered-frame count instead.
The percentage is frame-based, not a remaining-time estimate; inaccurate
duration metadata can also affect it.

## Picture and sound

The reference is [this iPhone 5 concert recording by @htx.a1dan](https://www.tiktok.com/@htx.a1dan/video/7690452679386025247), shared on TikTok. The processing follows its clipped stage lights, soft detail, saturated colors, motion smear, and compressed concert audio.

- **Video:** darker shadows, highlight bloom, slight frame blending, subtle noise, and compressed detail.
- **Audio:** mono, modest bass emphasis, vocal and crowd presence, and distortion and compression on loud passages.
- **Output:** QuickTime `.mov`, H.264 at 30 fps, Rec.709 SDR, and mono AAC audio. Landscape and portrait 16:9 footage fits 1920×1080 or 1080×1920; other aspect ratios fit within those bounds. Smaller clips are upscaled.
- **HDR input:** standard HLG/PQ footage, including typical iPhone 15 Dolby Vision recordings with an HLG base layer, is tone-mapped to SDR.

This approximates the reference's appearance and audio character. The TikTok copy includes web compression, and a filter cannot reproduce the original camera position, stage lighting, lens, or exposure decisions. The app preserves your footage's lighting colors rather than adding the reference's red stage lighting. It uses one fixed treatment for all videos.

## Requirements

- macOS 14 or later.
- FFmpeg and ffprobe, available through [Homebrew](https://brew.sh):

```sh
brew install ffmpeg
```

The app looks for both tools in `/opt/homebrew/bin` or `/usr/local/bin`. They are not bundled with the app.

## Build

Install Apple's Command Line Tools with `xcode-select --install`. From the repository folder, run:

```sh
mkdir -p "iPhone 5 Generator.app/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  Sources/Converter.swift Sources/main.swift \
  -o "iPhone 5 Generator.app/Contents/MacOS/iPhone5Generator"
cp Info.plist "iPhone 5 Generator.app/Contents/Info.plist"
codesign --force --sign - "iPhone 5 Generator.app"
open "iPhone 5 Generator.app"
```

This builds a locally signed app for your Mac's architecture. The generated `.app` is excluded from Git.

## Source

```text
Sources/main.swift        Window, drag-and-drop, conversion and save flow
Sources/Converter.swift   FFmpeg video and audio processing
Info.plist                macOS application metadata
```
