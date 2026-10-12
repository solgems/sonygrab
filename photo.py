"""Photo downsizing for social upload.

A 24MP 6000x4000 frame is ~12 MB and no social platform shows more than a
fraction of it -- Instagram tops out around 1080px on the long edge, Facebook
around 2048. Resizing before upload means you control the quality loss instead
of letting their encoder do it.

EXIF is carried across (so capture date, camera and lens survive), with an
option to drop GPS -- these files are destined for the public internet.
"""

from __future__ import annotations

import io
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

try:
    from PIL import Image, ImageOps
    HAVE_PIL = True
except ImportError:                                   # pragma: no cover
    HAVE_PIL = False

# Pillow reads these directly. HEIF needs a plugin, so it falls back to sips.
PIL_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"}
HEIF_EXTS = {".hif", ".heif", ".heic"}
RAW_EXTS = {".arw", ".sr2", ".srf"}

# Long-edge presets. Instagram displays 1080; 2048 is Facebook's ceiling and
# leaves room to crop. 2560 is a comfortable "good everywhere" default.
SIZE_PRESETS = {
    "1080": ("1080 px — Instagram native", 1080),
    "2048": ("2048 px — Facebook / WhatsApp", 2048),
    "2560": ("2560 px — good everywhere", 2560),
    "3840": ("3840 px — 4K, minimal loss", 3840),
    "full": ("Full size — quality only", 0),
}

# EXIF tag ids we handle explicitly.
_GPS_IFD = 0x8825
_ORIENTATION = 0x0112


@dataclass
class PhotoResult:
    ok: bool
    src: str
    out: str = ""
    src_size: int = 0
    out_size: int = 0
    src_wh: tuple[int, int] = (0, 0)
    out_wh: tuple[int, int] = (0, 0)
    skipped: bool = False
    reason: str = ""
    error: str = ""


def can_resize(path: str | Path) -> bool:
    ext = Path(path).suffix.lower()
    return (ext in PIL_EXTS and HAVE_PIL) or (ext in HEIF_EXTS and bool(shutil.which("sips")))


def out_path_for(src: str | Path, dest_dir: str | Path, suffix: str = "",
                 on_exists: str = "rename") -> Path:
    """Where a resized copy of `src` belongs.

    on_exists decides what happens when that name is taken:

      skip / replace  return the plain name and let the caller decide. An
                      import re-run wants this -- the point of re-running is
                      to fill gaps, not to accumulate DSC01404-1, -2, -3.
      rename          pick the next free "-N" name. Right for "compress this
                      one file", where asking twice means wanting two outputs.
    """
    s = Path(src)
    d = Path(dest_dir)
    # HEIF becomes JPEG -- universally accepted, unlike .HIF.
    ext = ".jpg" if s.suffix.lower() in HEIF_EXTS else s.suffix
    out = d / f"{s.stem}{suffix}{ext}"
    if on_exists != "rename":
        return out
    n = 1
    while out.exists():
        out = d / f"{s.stem}{suffix}-{n}{ext}"
        n += 1
    return out


def _strip_gps(exif) -> None:
    try:
        if _GPS_IFD in exif:
            del exif[_GPS_IFD]
    except (KeyError, TypeError):
        pass
    # Pillow exposes GPS through a sub-IFD accessor on newer versions too.
    try:
        gps = exif.get_ifd(_GPS_IFD)
        if gps:
            gps.clear()
    except (AttributeError, KeyError, TypeError):
        pass


def resize(
    src: str | Path,
    dest_dir: str | Path,
    long_edge: int = 2560,
    quality: int = 85,
    strip_gps: bool = True,
    suffix: str = "",
    on_exists: str = "skip",
) -> PhotoResult:
    s = Path(src)
    r = PhotoResult(ok=False, src=str(s))
    try:
        r.src_size = s.stat().st_size
    except OSError as e:
        r.error = str(e)
        return r

    ext = s.suffix.lower()

    if on_exists == "skip":
        done = out_path_for(s, dest_dir, suffix, on_exists)
        if done.exists():
            r.skipped, r.ok = True, True
            r.out = str(done)
            try:
                r.out_size = done.stat().st_size
            except OSError:
                pass
            r.reason = "already imported"
            return r

    if ext in RAW_EXTS:
        r.skipped, r.ok = True, True
        r.reason = "RAW — left as-is (not a social format)"
        return r

    if ext in HEIF_EXTS:
        return _resize_heif(s, Path(dest_dir), long_edge, quality, suffix, r,
                            on_exists)

    if not HAVE_PIL or ext not in PIL_EXTS:
        r.skipped, r.ok = True, True
        r.reason = "unsupported image type — copied unchanged"
        return r

    try:
        with Image.open(s) as im:
            r.src_wh = im.size
            exif = im.getexif()

            # Bake in the orientation flag, then clear it so viewers don't
            # rotate a second time.
            im = ImageOps.exif_transpose(im)
            try:
                if _ORIENTATION in exif:
                    del exif[_ORIENTATION]
            except (KeyError, TypeError):
                pass

            if strip_gps:
                _strip_gps(exif)

            w, h = im.size
            if long_edge and max(w, h) > long_edge:
                f = long_edge / max(w, h)
                im = im.resize((max(1, round(w * f)), max(1, round(h * f))),
                               Image.LANCZOS)
            r.out_wh = im.size

            out = out_path_for(s, dest_dir, suffix, on_exists)
            out.parent.mkdir(parents=True, exist_ok=True)

            if im.mode in ("RGBA", "P", "LA"):
                im = im.convert("RGB")

            tmp = out.with_name(out.name + ".partial")
            im.save(tmp, "JPEG", quality=quality, optimize=True,
                    progressive=True, subsampling="4:2:0",
                    exif=exif.tobytes() if exif else b"")
            tmp.replace(out)

        shutil.copystat(s, out)          # keep the capture timestamp
        r.out = str(out)
        r.out_size = out.stat().st_size
        r.ok = True
        return r

    except (OSError, ValueError, SyntaxError) as e:
        r.error = f"{type(e).__name__}: {e}"
        return r


def _resize_heif(s: Path, dest_dir: Path, long_edge: int, quality: int,
                 suffix: str, r: PhotoResult,
                 on_exists: str = "skip") -> PhotoResult:
    """Sony .HIF via sips, since Pillow has no HEIF support here."""
    if not shutil.which("sips"):
        r.skipped, r.ok = True, True
        r.reason = "HEIF needs sips — copied unchanged"
        return r
    out = out_path_for(s, dest_dir, suffix, on_exists)
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        cmd = ["sips", "-s", "format", "jpeg",
               "-s", "formatOptions", str(max(1, min(100, quality))),
               str(s), "--out", str(out)]
        if long_edge:
            cmd[1:1] = ["-Z", str(long_edge)]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if res.returncode != 0 or not out.is_file():
            r.error = (res.stderr or "sips failed").strip().splitlines()[-1:][0] if res.stderr else "sips failed"
            return r
        shutil.copystat(s, out)
        r.out = str(out)
        r.out_size = out.stat().st_size
        r.ok = True
        return r
    except (OSError, subprocess.SubprocessError) as e:
        r.error = str(e)
        return r


def estimate_out_size(src_size: int, src_wh: tuple[int, int], long_edge: int,
                      quality: int = 85) -> int:
    """Rough predicted size, for showing a total before the work starts."""
    w, h = src_wh
    if not w or not h:
        return src_size
    if not long_edge or max(w, h) <= long_edge:
        pixel_ratio = 1.0
    else:
        pixel_ratio = (long_edge / max(w, h)) ** 2
    # JPEG size tracks pixel count sub-linearly; q85 re-encode of a q95 source
    # lands near 0.55 of the naive scaling.
    q_factor = 0.55 * (quality / 85) ** 1.6
    return max(20_000, int(src_size * pixel_ratio * q_factor))
