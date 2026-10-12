"""SonyGrab core: find Sony camera cards, read capture dates, copy media off them.

Read-only with respect to the card. Nothing here deletes, renames, or writes to
the source volume -- the only write path is into the destination folder.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------- file types

STILL_RAW = {".arw", ".sr2", ".srf"}
STILL_JPEG = {".jpg", ".jpeg", ".hif", ".heif", ".heic"}
VIDEO = {".mp4", ".mts", ".m2ts", ".mov", ".avi"}

MEDIA_EXTS = STILL_RAW | STILL_JPEG | VIDEO

KIND_RAW, KIND_JPEG, KIND_VIDEO = "raw", "jpeg", "video"


def kind_of(path: Path) -> str | None:
    ext = path.suffix.lower()
    if ext in STILL_RAW:
        return KIND_RAW
    if ext in STILL_JPEG:
        return KIND_JPEG
    if ext in VIDEO:
        return KIND_VIDEO
    return None


# Where Sony bodies actually put things.  DCIM covers stills on every model;
# M4ROOT/CLIP is XAVC S/HS video; AVCHD/BDMV/STREAM is the older MTS format;
# MP_ROOT is the legacy Cyber-shot / Handycam MP4 location.
MEDIA_SUBDIRS = [
    "DCIM",
    "PRIVATE/M4ROOT",
    "M4ROOT",
    "PRIVATE/AVCHD",
    "AVCHD",
    "PRIVATE/SONY",
    "MP_ROOT",
    "CLIP",
]

# Any of these at the volume root means "this is a camera card".
CARD_MARKERS = ["DCIM", "PRIVATE", "AVCHD", "MP_ROOT", "M4ROOT", "AVF_INFO"]

# Directory names that are metadata, not media.
SKIP_DIRS = {".Spotlight-V100", ".Trashes", ".fseventsd", "AVF_INFO", "GENERAL"}


# ------------------------------------------------------------ card detection

@dataclass
class Card:
    path: str
    name: str
    is_sony: bool
    markers: list[str]
    total_bytes: int
    free_bytes: int


def _volume_stats(p: Path) -> tuple[int, int]:
    try:
        st = os.statvfs(p)
        return st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
    except OSError:
        return 0, 0


def detect_cards() -> list[Card]:
    """Every mounted volume that looks like a camera card, Sony first."""
    cards: list[Card] = []
    vol_root = Path("/Volumes")
    if not vol_root.is_dir():
        return cards

    for vol in sorted(vol_root.iterdir()):
        try:
            if vol.name.startswith(".") or not vol.is_dir():
                continue
            # Skip the boot volume symlink.
            if vol.is_symlink() and vol.resolve() == Path("/"):
                continue
        except OSError:
            continue

        markers = []
        for m in CARD_MARKERS:
            try:
                if (vol / m).is_dir():
                    markers.append(m)
            except OSError:
                continue
        if not markers:
            continue

        # Sony-specific fingerprints inside PRIVATE/.
        sony = any(
            (vol / p).is_dir()
            for p in ("PRIVATE/SONY", "PRIVATE/M4ROOT", "M4ROOT", "MP_ROOT", "AVF_INFO")
        )
        if not sony:
            # Sony still folders are named like 100MSDCF.
            dcim = vol / "DCIM"
            if dcim.is_dir():
                try:
                    sony = any(re.fullmatch(r"\d{3}MSDCF", d.name) for d in dcim.iterdir())
                except OSError:
                    pass

        total, free = _volume_stats(vol)
        cards.append(
            Card(
                path=str(vol),
                name=vol.name,
                is_sony=sony,
                markers=markers,
                total_bytes=total,
                free_bytes=free,
            )
        )

    cards.sort(key=lambda c: (not c.is_sony, c.name))
    return cards


# ------------------------------------------------------------------ scanning

@dataclass
class MediaFile:
    src: str
    name: str
    kind: str
    size: int
    shot_at: str          # ISO-8601 local time, "" if genuinely unknown
    date_source: str      # exif | quicktime | filesystem
    month: str            # YYYY-MM, "" if unknown
    day: str              # YYYY-MM-DD, "" if unknown -- the primary selector
    rel_dir: str          # where it sat on the card, for context in the UI


def _walk_media(root: Path) -> list[Path]:
    found: list[Path] = []
    seen_dirs: set[Path] = set()

    def walk(base: Path) -> None:
        try:
            resolved = base.resolve()
        except OSError:
            return
        if resolved in seen_dirs:
            return
        seen_dirs.add(resolved)
        try:
            entries = list(base.iterdir())
        except OSError:
            return
        for e in entries:
            try:
                if e.name.startswith("._") or e.name in SKIP_DIRS:
                    continue
                if e.is_dir():
                    walk(e)
                elif e.is_file() and kind_of(e):
                    found.append(e)
            except OSError:
                continue

    for sub in MEDIA_SUBDIRS:
        d = root / sub
        if d.is_dir():
            walk(d)

    # Some bodies drop clips at the volume root; catch those too, shallowly.
    try:
        for e in root.iterdir():
            if e.is_file() and kind_of(e) and not e.name.startswith("._"):
                found.append(e)
    except OSError:
        pass

    return sorted(set(found))


_EXIF_DATE_TAGS = [
    "DateTimeOriginal",
    "CreateDate",
    "MediaCreateDate",
    "TrackCreateDate",
    "ContentCreateDate",
]

_DATE_RE = re.compile(r"^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})")


def _parse_exif_date(value) -> datetime | None:
    if not isinstance(value, str):
        return None
    m = _DATE_RE.match(value.strip())
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    if not (1970 <= y <= 2100 and 1 <= mo <= 12 and 1 <= d <= 31):
        return None
    try:
        return datetime(y, mo, d, h, mi, s)
    except ValueError:
        return None


def _exif_dates(paths: list[Path]) -> dict[str, tuple[datetime, str]]:
    """Batch-read capture dates. One exiftool process for the whole card.

    -api QuickTimeUTC=1 makes exiftool convert MP4/MOV UTC timestamps into local
    time, which matters at month boundaries -- without it a clip shot at 9pm on
    Jul 31 local reads as Aug 1.
    """
    out: dict[str, tuple[datetime, str]] = {}
    if not paths or not shutil.which("exiftool"):
        return out

    args = ["exiftool", "-json", "-fast2", "-api", "QuickTimeUTC=1", "-charset", "filename=utf8"]
    for tag in _EXIF_DATE_TAGS:
        args.append(f"-{tag}")
    args.append("-@")

    # Feed paths on stdin so we never hit ARG_MAX on a full card.
    listing = "\n".join(str(p) for p in paths) + "\n"
    try:
        proc = subprocess.run(
            args + ["-"],
            input=listing,
            capture_output=True,
            text=True,
            timeout=600,
        )
        data = json.loads(proc.stdout or "[]")
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError):
        return out

    for entry in data:
        src = entry.get("SourceFile")
        if not src:
            continue
        for tag in _EXIF_DATE_TAGS:
            dt = _parse_exif_date(entry.get(tag))
            if dt:
                source = "exif" if tag == "DateTimeOriginal" else "quicktime"
                out[os.path.realpath(src)] = (dt, source)
                break
    return out


def scan_card(card_path: str) -> list[MediaFile]:
    root = Path(card_path)
    paths = _walk_media(root)
    dates = _exif_dates(paths)

    files: list[MediaFile] = []
    for p in paths:
        try:
            size = p.stat().st_size
        except OSError:
            continue

        key = os.path.realpath(p)
        if key in dates:
            dt, source = dates[key]
        else:
            try:
                dt, source = datetime.fromtimestamp(p.stat().st_mtime), "filesystem"
            except (OSError, OverflowError, ValueError):
                dt, source = None, "unknown"

        try:
            rel_dir = str(p.parent.relative_to(root))
        except ValueError:
            rel_dir = str(p.parent)

        files.append(
            MediaFile(
                src=str(p),
                name=p.name,
                kind=kind_of(p) or "",
                size=size,
                shot_at=dt.isoformat(timespec="seconds") if dt else "",
                date_source=source,
                month=dt.strftime("%Y-%m") if dt else "",
                day=dt.strftime("%Y-%m-%d") if dt else "",
                rel_dir=rel_dir,
            )
        )

    files.sort(key=lambda f: (f.shot_at or "0", f.name))
    return files


def day_summary(files: list[MediaFile]) -> list[dict]:
    """Per-day rollup, newest first. This is what the picker is built on:
    one row per shooting date, with counts and size so you can confirm
    before importing."""
    buckets: dict[str, dict] = {}
    for f in files:
        day = f.day or "unknown"
        b = buckets.setdefault(
            day,
            {"day": day, "month": f.month or "unknown", "count": 0, "bytes": 0,
             "raw": 0, "jpeg": 0, "video": 0, "photos": 0,
             "first": "", "last": ""},
        )
        b["count"] += 1
        b["bytes"] += f.size
        if f.kind:
            b[f.kind] += 1
        if f.kind in (KIND_RAW, KIND_JPEG):
            b["photos"] += 1
        t = f.shot_at[11:16] if len(f.shot_at) >= 16 else ""
        if t:
            if not b["first"] or t < b["first"]:
                b["first"] = t
            if not b["last"] or t > b["last"]:
                b["last"] = t
    return sorted(buckets.values(), key=lambda b: b["day"], reverse=True)


def month_summary(files: list[MediaFile]) -> list[dict]:
    """Per-month rollup, newest first -- used for the month quick-filters."""
    buckets: dict[str, dict] = {}
    for f in files:
        b = buckets.setdefault(
            f.month or "unknown",
            {"month": f.month or "unknown", "count": 0, "bytes": 0,
             "raw": 0, "jpeg": 0, "video": 0},
        )
        b["count"] += 1
        b["bytes"] += f.size
        if f.kind:
            b[f.kind] += 1
    return sorted(buckets.values(), key=lambda b: b["month"], reverse=True)


# ------------------------------------------------------------------- copying

@dataclass
class Progress:
    state: str = "idle"          # idle | copying | verifying | done | error | cancelled
    total_files: int = 0
    done_files: int = 0
    skipped_files: int = 0
    total_bytes: int = 0
    done_bytes: int = 0
    current: str = ""
    dest: str = ""
    started_at: float = 0.0
    finished_at: float = 0.0
    errors: list[str] = field(default_factory=list)
    log: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        d = asdict(self)
        elapsed = (self.finished_at or time.time()) - self.started_at if self.started_at else 0
        d["elapsed"] = round(elapsed, 1)
        rate = self.done_bytes / elapsed if elapsed > 0.5 else 0
        d["rate_bytes_sec"] = rate
        remaining = self.total_bytes - self.done_bytes
        d["eta_sec"] = round(remaining / rate) if rate > 0 and remaining > 0 else None
        d["log"] = self.log[-200:]
        return d


def _sha256(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def dest_path_for(f: MediaFile, dest_root: Path, layout: str) -> Path:
    """Where a file should land. Never returns a path outside dest_root."""
    if layout == "by-day" and f.day:
        sub = f.day                                # YYYY-MM-DD
    elif layout == "by-type":
        sub = {"video": "Video", "raw": "RAW", "jpeg": "JPEG"}.get(f.kind, "Other")
    else:
        sub = ""
    name = os.path.basename(f.name)                # defensive: strip any path parts
    return (dest_root / sub / name) if sub else (dest_root / name)


def _unique(path: Path) -> Path:
    """Same name, different file -> add a counter rather than overwrite."""
    if not path.exists():
        return path
    stem, suffix, n = path.stem, path.suffix, 1
    while True:
        cand = path.with_name(f"{stem}-{n}{suffix}")
        if not cand.exists():
            return cand
        n += 1


def copy_files(
    files: list[MediaFile],
    dest_root: str,
    layout: str = "flat",
    verify: bool = False,
    progress: Progress | None = None,
    cancel=lambda: False,
) -> Progress:
    p = progress or Progress()
    dest = Path(dest_root).expanduser()
    p.dest = str(dest)
    p.state = "copying"
    p.total_files = len(files)
    p.total_bytes = sum(f.size for f in files)
    p.started_at = time.time()

    try:
        dest.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        p.state = "error"
        p.errors.append(f"Cannot create destination: {e}")
        p.finished_at = time.time()
        return p

    free = shutil.disk_usage(dest).free
    if p.total_bytes > free * 0.98:
        p.state = "error"
        p.errors.append(
            f"Not enough space: need {human(p.total_bytes)}, {human(free)} free on the destination."
        )
        p.finished_at = time.time()
        return p

    copied: list[tuple[Path, Path]] = []

    for f in files:
        if cancel():
            p.state = "cancelled"
            p.finished_at = time.time()
            return p

        src = Path(f.src)
        target = dest_path_for(f, dest, layout)
        p.current = f.name

        try:
            target.parent.mkdir(parents=True, exist_ok=True)

            # Already there at the same size -> treat as done, don't recopy.
            if target.exists() and target.stat().st_size == f.size:
                p.skipped_files += 1
                p.done_files += 1
                p.done_bytes += f.size
                p.log.append(f"skip (already present)  {f.name}")
                continue
            if target.exists():
                target = _unique(target)

            tmp = target.with_name(target.name + ".partial")
            with open(src, "rb") as r, open(tmp, "wb") as w:
                while True:
                    if cancel():
                        w.close()
                        tmp.unlink(missing_ok=True)
                        p.state = "cancelled"
                        p.finished_at = time.time()
                        return p
                    chunk = r.read(4 << 20)
                    if not chunk:
                        break
                    w.write(chunk)
                    p.done_bytes += len(chunk)

            shutil.copystat(src, tmp)      # keep capture mtime
            tmp.replace(target)
            copied.append((src, target))
            p.done_files += 1
            p.log.append(f"copied  {f.name}  ({human(f.size)})")

        except (OSError, shutil.Error) as e:
            p.errors.append(f"{f.name}: {e}")
            p.log.append(f"FAILED  {f.name}: {e}")
            p.done_files += 1

    if verify and copied:
        p.state = "verifying"
        p.done_files = 0
        p.total_files = len(copied)
        for src, target in copied:
            if cancel():
                p.state = "cancelled"
                p.finished_at = time.time()
                return p
            p.current = target.name
            try:
                if _sha256(src) != _sha256(target):
                    p.errors.append(f"{target.name}: checksum mismatch")
                    p.log.append(f"MISMATCH  {target.name}")
                else:
                    p.log.append(f"verified  {target.name}")
            except OSError as e:
                p.errors.append(f"{target.name}: verify failed: {e}")
            p.done_files += 1

    p.state = "done" if not p.errors else "error"
    p.current = ""
    p.finished_at = time.time()
    return p


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"
