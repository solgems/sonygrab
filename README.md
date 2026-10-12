# SonyGrab

Pull photos and video off a Sony camera card by shooting date, and make
social-ready versions on the way in.

## Download

**[Download SonyGrab for Mac](https://github.com/solgems/sonygrab/releases/latest/download/SonyGrab.zip)**

For Apple silicon Macs (M1 or newer). About 65 MB, and nothing else needs
installing.

macOS blocks the first launch, because the app is not signed by a registered
Apple developer. Getting past that takes a minute, once:

1. In Downloads, drag **SonyGrab** into **Applications**. Do this before
   opening it. If you see `SonyGrab.zip` instead, double-click it first.
2. Open SonyGrab from Applications. macOS says it cannot be opened. Click
   **Done** or **Cancel**. **Do not click Move to Trash.**
3. Open **System Settings → Privacy & Security**, scroll down to the note about
   SonyGrab and click **Open Anyway**. Enter your Mac password if asked.
4. Open SonyGrab again and choose **Open**. It appears in your web browser.

After that it opens normally and keeps itself up to date. The first time you
import, macOS may ask to let it read the card. Click **Allow**.

## Run it

Double-click **SonyGrab.app**. It opens in your browser — no terminal, no Dock clutter.

Double-clicking it again while it's already running just reopens the tab rather than
starting a second copy.

**To stop it:** the **Quit** button at the top right of the page. If you forget, it
shuts itself down after 15 minutes idle (never mid-import).

Other ways in, if you prefer a terminal:

    python3 server.py          # Ctrl-C to quit
    ./SonyGrab.command         # same, in its own Terminal window

### Putting it somewhere you'll find it

Drag `SonyGrab.app` to **/Applications** (then it's in Spotlight — ⌘-Space, "sonygrab")
or straight onto your **Dock**. The app is self-contained, so it works from anywhere.

Logs go to `~/Library/Logs/SonyGrab.log`.

### Rebuilding the app

`SonyGrab.app` contains a copy of the code. After editing any `.py` or `ui.html`:

    ./build_app.sh

Run `./fetch_vendor.sh` once beforehand and the bundle also carries its own Python,
ffmpeg and exiftool, so it runs on a Mac with nothing installed. See
[Giving it to another Mac](#giving-it-to-another-mac).

A build made this way never updates itself, so it always runs exactly the code
you built. `./release.sh` makes the ones that do.

Then check the build end to end:

    ./smoke_test.sh

It starts the built app the way Finder would, with the developer tools and
Homebrew blocked, imports a pretend card and checks what landed on disk. It
uses its own home folder and opens no browser window, so it is safe to run
while a real import is going.

## Two tabs

### Import from card

1. Insert a card — detected automatically.
2. Every shooting date, newest first, with **photo count, video count and size**.
3. Tick dates, or use the quick filters (Today / Last 7 days / This month).
4. The bottom bar shows the running total and what will be written:
   *"232 MB originals + ~24 MB social → ~/Pictures/Sony"*.
5. **Import** confirms those numbers, then copies and compresses.

### Compress a video

Point it at any video already on disk, pick a platform, see the predicted size,
compress. Independent of the card.

## Compression

On by default for both photos and video. Originals are kept unless you say otherwise.

    <dest>/2026-08-25/DSC00101.JPG          original, byte-identical
    <dest>/2026-08-25/Social/DSC00101.jpg    2560px, ~1 MB
    <dest>/2026-08-25/Social/C0001-reels.mp4 1080p H.264

Turn off *Keep the originals* and the social versions land directly in the date
folder with no originals kept.

Importing the same shoot twice changes nothing. Anything already there is left
alone rather than copied again beside itself. The *Compress a video* tab is the
exception: asking it to compress one file twice means you want two outputs, so
the second lands as `name-reels-1.mp4`.

### Photos

A 24MP 6000×4000 frame is ~11 MB. Nothing on social shows more than a fraction of it —
Instagram displays about 1080px on the long edge, Facebook about 2048.

| Long edge | 6000×4000 becomes | Typical size |
|---|---|---|
| 1080 px | 1080×720 | ~0.15 MB |
| 2048 px | 2048×1365 | ~0.75 MB |
| 2560 px *(default)* | 2560×1707 | ~1.2 MB |
| 3840 px | 3840×2560 | ~2.6 MB |

EXIF survives — camera, lens, capture date, exposure. **GPS is stripped by default**,
since these files are headed for the public internet; untick to keep it.
RAW is copied untouched, never resized.

### Video

| Preset | Output | Notes |
|---|---|---|
| Reels / TikTok / Shorts | 1080p, CRF 21 | TikTok caps mobile uploads near 290 MB |
| Instagram Feed / Facebook | 1080p, CRF 21 | Quality-first |
| YouTube | 1080p, CRF 20 | Higher bitrate; YouTube re-encodes anyway |
| X / Twitter | 1080p, CRF 23 | 512 MB and 2:20 on free accounts |
| Messaging / email | 720p, CRF 26 | Small above all |

Two ways to target:

- **Best quality** — CRF with a bitrate ceiling. Size varies with the footage.
- **Fit under N MB** — two-pass VBR. Lands within a few percent of the number.

Output is H.264 High / yuv420p / AAC with `+faststart`, which is what every platform
wants. **Fast (hardware)** uses Apple VideoToolbox — roughly 2× quicker, marginally
larger for the same quality.

A 5-minute 4K clip takes roughly 2 minutes to compress on an M1, or about 1 with
the hardware encoder.

### HDR

Sony picture profiles like HLG record BT.2020 HDR. Uploaded straight, most platforms
render that washed out or too dark. SonyGrab detects HLG and PQ sources and converts
to BT.709 automatically. If you switch it off, it says what will happen.

## Why not just drag DCIM to the desktop

Sony splits media across two trees:

    DCIM/100MSDCF/          stills  (.JPG .ARW .HIF)
    PRIVATE/M4ROOT/CLIP/    XAVC S / XAVC HS video (.MP4)
    AVCHD/BDMV/STREAM/      older AVCHD video (.MTS)

Drag `DCIM` and you silently leave every video behind.

## Dates

Capture dates come from EXIF via `exiftool` — `DateTimeOriginal` for stills, the
QuickTime creation tags for video — not file timestamps. QuickTime stores UTC, so
it's converted to local time; without that a clip shot at 23:30 on Jul 31 files
itself under August. Files with no EXIF date fall back to mtime.

## Safety

- The card is only read. Nothing deletes, renames or writes to it.
- Copies are written to a `.partial` name and renamed on completion.
- Re-importing the same card is a no-op. Files already copied are skipped on
  size, and social versions already made are skipped on name, so nothing is
  duplicated and nothing is redone.
- Cancel keeps completed files and removes only the one in flight.
- Compression never writes over its source.
- Capture timestamps are preserved on every copy.

## Giving it to another Mac

Send them the link in [Download](#download). The app carries its own Python and
tools, so the Mac receiving it needs nothing installed. No Homebrew, no pip, no
developer tools, no Terminal.

Step 1 there matters. macOS runs a downloaded app from a locked temporary copy
until it has been moved, and the app cannot unblock its own tools from there.
Once it is in Applications and has been allowed to open, the launcher clears
the quarantine flag off the bundled Python, ffmpeg and exiftool by itself.

A USB stick avoids the dialog entirely, because quarantine is applied by the
program doing the downloading rather than by the network. `curl`, `scp` and a
copy from a mounted share do not set it; Safari, Mail and AirDrop do.

If a copy is already blocked, this clears it without the System Settings trip:

    xattr -dr com.apple.quarantine /Applications/SonyGrab.app

### Why the app is unsigned

Deliberate. An ad-hoc signature buys nothing against Gatekeeper, and it seals a
folder that cannot stay sealed, since the updater rewrites code inside the
bundle. macOS treats a quarantined bundle whose signature no longer verifies as
damaged and deletes it outright.

Paying for an Apple Developer ID and notarizing would remove the first-launch
dialog, at $99 a year. It would also mean moving the updatable code out of the
bundle to keep the seal intact.

## Updates

Once installed, a Mac keeps itself current. On launch it asks GitHub for the
latest release's manifest, and if that is newer than what it has, it pulls the
changed code into its own bundle. Only the ~100 KB of Python and HTML travels.
The 160 MB of bundled tools stays put and is versioned separately, so a release
that needs newer ones is refused rather than half-applied.

Updates are only ever fetched over HTTPS from this repository's releases, and
every file is checked against the hash in the manifest before anything is
replaced.

Every failure is "carry on with what we have". No network, a download that
does not match its hash, a read-only bundle: the app just launches. It only
ever moves forward, never back to an older release, and never while a copy is
already running.

### Ship a change

    git commit -am "what changed"
    ./release.sh 1.0.1 --publish

That builds the app, runs `smoke_test.sh` on it and publishes a GitHub release
holding both the new `SonyGrab.zip` and the update files. Every installed Mac
picks it up the next time the app is opened. Without `--publish` it stops after
building `release/`, for a look first.

The version has to be higher than the last one, or installed copies ignore it.

## Requirements

An Apple silicon Mac, for a bundle built after `./fetch_vendor.sh`. Nothing has to
be installed on it: no developer tools, no Homebrew, no Rosetta. It carries:

| Bundled | Version | For |
|---|---|---|
| Python | 3.12.15, standalone build | running the app |
| Pillow | 12.3.0, installed into that Python | photo resizing |
| ffmpeg + ffprobe | 9.0, static arm64 | video compression |
| exiftool | 13.59, pure Perl | capture dates |

From macOS itself it uses `perl` (exiftool runs on it), `sips` (Sony `.HIF`) and
`osascript` (the folder pickers). All three are part of a stock Mac.

Photo importing works from macOS 11. The bundled ffmpeg needs macOS 12, so video
compression does too.

The bundled copies take priority, so every Mac runs identical tools. If the
bundled Python cannot start, the launcher falls back to a `python3` already on
the Mac, and failing that says what to do. Each launch writes one line to
`~/Library/Logs/SonyGrab.log` saying which it was.

Build without `vendor/` and you get the small bundle that leans on whatever the Mac
already has:

    brew install python exiftool ffmpeg   # the app, dates, video
    pip3 install Pillow                   # photo resizing

Each tool is optional; the UI says so and disables what it can't do.

## Files

    fetch_vendor.sh  downloads Python, Pillow, ffmpeg and exiftool into vendor/
    build_app.sh     assembles SonyGrab.app  (--out, --update-url, --version)
    smoke_test.sh    end-to-end check of a built app
    release.sh       builds, tests and publishes a release
    THIRD_PARTY.md   what the app bundles, and under which licences
    vendor/          the bundled Python and tools, created by fetch_vendor.sh

    core.py       card detection, scanning, EXIF dates, copying
    photo.py      photo resizing (Pillow, sips for HEIF)
    compress.py   ffprobe/ffmpeg video compression
    pipeline.py   one import job: copy, then social versions
    server.py     loopback HTTP server + JSON API
    ui.html       the interface
