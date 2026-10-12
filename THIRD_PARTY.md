# Third-party software in SonyGrab.app

SonyGrab's own code is the Python and HTML in this repository. The app bundle
also carries the programs below. Each is unmodified and is run as a separate
program; none of it is linked into SonyGrab's code.

| Component | Version | Licence | Source |
|---|---|---|---|
| FFmpeg (`ffmpeg`, `ffprobe`) | 9.0 | GPL, version 2 or later | <https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz> |
| ExifTool | 13.59 | Same terms as Perl (Artistic License or GPL) | <https://exiftool.org> |
| CPython | 3.12.15 | Python Software Foundation License | <https://www.python.org/downloads/source/> |
| Pillow | 12.3.0 | MIT-CMU | <https://github.com/python-pillow/Pillow> |

## FFmpeg

The `ffmpeg` and `ffprobe` binaries are the static Apple silicon builds
published at <https://www.osxexperts.net>, redistributed here unchanged. They
are licensed under the GNU General Public License, version 2 or later. The
text of that licence is in [licenses/GPL-2.0.txt](licenses/GPL-2.0.txt) and
inside the app at `Contents/Resources/licenses/GPL-2.0.txt`.

The builds are statically linked with other libraries, x264 and x265 among
them. `ffmpeg -version` prints the full list in its `configuration:` line.
Each of those libraries is available from its own project.

## The others

- CPython is the relocatable build from
  <https://github.com/astral-sh/python-build-standalone>. Its licence is
  inside the app at `Contents/Resources/vendor/python/lib/python3.12/LICENSE.txt`.
- Pillow's licence is inside the app, in the `pillow-*.dist-info/licenses`
  folder next to the package.
- ExifTool's licence statement is at the end of
  `Contents/Resources/vendor/exiftool/exiftool`.

`fetch_vendor.sh` records exactly where each of these is downloaded from.
