```text
----------------------------------------------------------------------
                       iPhone 5 Generator
                           Version 1.0
                  Video Conversion Utility for Mac
----------------------------------------------------------------------

  H.264 Video  /  1080p  /  30 fps  /  Mono AAC Audio

  README                              Installation & User's Guide
----------------------------------------------------------------------
```

Convert a video to approximate the picture and sound of the iPhone 5
rear camera. Drag a file into the window, wait for conversion to finish,
and save the QuickTime movie. All processing takes place on your Mac.

### Contents

1. [System Requirements & Installation](#1-system-requirements--installation)
2. [Getting Started](#2-getting-started)
3. [Output Specifications](#3-output-specifications)
4. [Notes & Known Limitations](#4-notes--known-limitations)
5. [Building from Source](#5-building-from-source)
6. [Diagnostics & Command Line](#6-diagnostics--command-line)

---

## 1. System Requirements & Installation

```text
  Operating system : macOS 14 or later
  Required software: FFmpeg and ffprobe
  Supported input  : MOV, MP4 and other FFmpeg-readable video files
  Output file      : QuickTime Movie (.mov)
```

Double-click **iPhone 5 Generator.app** in this folder.

Requires macOS 14 or later and FFmpeg (already available on the Mac where this was built). On another Mac, install [Homebrew](https://brew.sh), then:

```sh
brew install ffmpeg
```

The app finds `ffmpeg` and `ffprobe` in `/opt/homebrew/bin` or `/usr/local/bin`. The built app targets the architecture of the Mac that builds it; rebuild for a different architecture. FFmpeg is an external dependency, not bundled into the app.

## 2. Getting Started

The main window follows the layout of a traditional desktop file utility:

```text
  +---------------------- iPhone 5 Generator ----------------------+
  | [ Open... ] [ Stop ]                                          |
  +--------------------+------------------------------------------+
  | OUTPUT PROFILE     | Filename              | Format | Status   |
  |                    +------------------------------------------+
  | Device:            |                                          |
  | Apple iPhone 5     |             Drag in your video            |
  |                    |                                          |
  | Video:             |                 [ Open... ]              |
  | H.264 / 1080p      |                                          |
  |                    |                                          |
  | Audio:             |                                          |
  | AAC / Mono         |                                          |
  +--------------------+------------------------------------------+
  | Ready              | 0 files                                  |
  +---------------------------------------------------------------+
```

The **Output Profile** panel lists the fixed conversion settings. The
striped file area displays the video being processed. One file is
converted at a time.

1. Drag a video from Finder into the window, or click **Open…** (`Command-O`).
2. A spinning circle appears during conversion. Click **Stop** to cancel.
3. The native macOS Save dialog opens when the video is ready.
4. Save it and the original screen returns. Canceling the Save dialog discards the temporary render and also returns to the original screen.

If saving fails, you can choose another location without rendering again. Input videos are never modified. The output contains the first video track and, when present, the first audio track; subtitles, location metadata, and other ancillary tracks are omitted.

## 3. Output Specifications

The target is the **rear camera of the iPhone 5**, not its 720p front camera. Apple's [technical specifications](https://support.apple.com/en-us/112016) document 1080p recording at up to 30 fps. Recording-format targets and estimated appearance adjustments are distinct:

| Part | Treatment |
| --- | --- |
| Resolution | 1920×1080 landscape or 1080×1920 portrait for 16:9 footage. Other aspect ratios fit within those bounds without cropping or stretching. Smaller videos are upscaled. |
| Motion | Constant 30 fps, dropping or repeating frames as needed; no artificial frame interpolation. |
| Video encoding | H.264 High / level 4.1, 8-bit 4:2:0, approximately 17 Mbps target, QuickTime MOV. Actual bitrate varies with content. |
| HDR | HLG/PQ detection, linear-light tone mapping, Rec.709 SDR output. Typical iPhone 15 Dolby Vision profile 8 recordings use their compatible HLG base layer; Dolby Vision dynamic metadata is not reproduced. |
| Detail | Slight optical-like softening followed by modest edge enhancement. |
| Tonality | A small contrast increase, slightly less shadow latitude and saturation. |
| Noise | Very subtle temporally varying luma/chroma noise, rather than exaggerated film grain. |
| Audio | Mono AAC, 44.1 kHz, 64 kbps; gentle bass/treble roll-off, a small presence emphasis, and mild compression. Silent inputs stay silent. |

## 4. Notes & Known Limitations

This is a restrained **approximation**, not a calibrated iPhone 5 sensor or microphone model. The filter and microphone EQ values are estimates; they have not been fitted to paired iPhone 5/iPhone 15 recordings. The iPhone 5 could produce clean, sharp daylight video, so the effect deliberately avoids a heavily damaged or VHS-like look.

Post-processing cannot recover the iPhone 5's original exposure, autofocus, rolling shutter, lens flare, motion blur, stabilization, or scene-dependent low-light noise from a modern recording. It also cannot undo modern computational processing. Framing is preserved rather than guessing the recording lens and cropping to a different field of view. Log footage without standard HLG/PQ tagging is not automatically camera-log normalized. Slow-motion edit decisions stored only in a Photos library must be baked into an exported video first.

For closer calibration, record the same scenes and sounds on both phones under matched lighting and framing, and tune `Sources/Converter.swift` against those reference clips.

## 5. Building from Source

Install Apple's Command Line Tools (`xcode-select --install`), then run:

```sh
bash build.sh
open "iPhone 5 Generator.app"
```

The app uses SwiftUI/AppKit and invokes FFmpeg on a background queue. No Python, web server, or package manager is needed to run the GUI. The build is locally ad-hoc signed, not notarized for distribution.

## 6. Diagnostics & Command Line

**FFmpeg not found:** Install FFmpeg using the command in Section 1.

**Unable to save:** Choose another folder in the Save dialog. The completed
conversion is retained while you choose a new location.

**Unable to open a video:** Check that the file plays normally and contains
a video track. Files with a `.mov` or `.mp4` extension can still be damaged
or contain unsupported media.

To run the converter checks (Python 3 required):

```sh
python3 Tests/smoke.py
```

The integration checks synthesize landscape, portrait, rotation-tagged, silent, HLG, and PQ clips and run the same converter used by the GUI. They verify decodability, dimensions, frame rate, SDR tags, duration, mono audio, invalid-input handling, and existing-output protection. They don't validate perceptual resemblance or interact with the GUI.

For a headless conversion:

```sh
"iPhone 5 Generator.app/Contents/MacOS/iPhone5Generator" --convert input.mov output.mov
```

The headless converter refuses to overwrite an existing output file.

---

```text
----------------------------------------------------------------------
  iPhone 5 Generator 1.0                               End of README
----------------------------------------------------------------------
```
