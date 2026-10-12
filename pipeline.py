"""One import job: copy originals off the card, then make social-ready versions.

Layout, with originals kept (the default):

    <dest>/2026-08-25/DSC00101.JPG        original, untouched
    <dest>/2026-08-25/Social/DSC00101.jpg  resized
    <dest>/2026-08-25/Social/C0001.mp4     compressed

Social versions are built from the copy on your disk rather than re-reading the
card -- faster, and it means the card is read exactly once.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path

import compress
import core
import photo

SOCIAL_DIRNAME = "Social"


@dataclass
class PhotoCfg:
    enabled: bool = True
    long_edge: int = 2560
    quality: int = 85
    strip_gps: bool = True
    # skip | replace | rename. Importing the same card twice should leave the
    # folder as it was, not fill it with "-1" copies.
    on_exists: str = "skip"


@dataclass
class VideoCfg:
    enabled: bool = True
    preset: str = "reels"
    mode: str = "quality"          # quality | size
    target_mb: float = 0.0
    fast: bool = False             # hardware encoder
    tonemap: bool | None = None    # None = auto (on for HDR sources)
    on_exists: str = "skip"        # see PhotoCfg


@dataclass
class JobProgress:
    state: str = "idle"       # idle|copying|photos|videos|done|error|cancelled
    phase_label: str = ""
    # copy phase
    copy_total: int = 0
    copy_done: int = 0
    copy_skipped: int = 0
    copy_bytes_total: int = 0
    copy_bytes_done: int = 0
    # photo phase
    photo_total: int = 0
    photo_done: int = 0
    photo_in: int = 0             # bytes read
    photo_out: int = 0            # bytes written
    # video phase
    video_total: int = 0
    video_done: int = 0
    video_pct: float = 0.0        # current clip
    video_in: int = 0
    video_out: int = 0
    video_eta: float | None = None

    current: str = ""
    dest: str = ""
    social_dirs: list[str] = field(default_factory=list)
    started_at: float = 0.0
    finished_at: float = 0.0
    errors: list[str] = field(default_factory=list)
    log: list[str] = field(default_factory=list)

    def note(self, msg: str) -> None:
        self.log.append(msg)
        del self.log[:-400]

    def as_dict(self) -> dict:
        d = asdict(self)
        el = (self.finished_at or time.time()) - self.started_at if self.started_at else 0
        d["elapsed"] = round(el, 1)

        # Overall progress: copy is weighted by bytes, media work by count.
        # Video dominates wall-clock, so it gets the largest share.
        w_copy = 1.0 if self.copy_total else 0.0
        w_photo = 1.0 if self.photo_total else 0.0
        w_video = 3.0 if self.video_total else 0.0
        tot_w = w_copy + w_photo + w_video
        if tot_w:
            f_copy = (self.copy_bytes_done / self.copy_bytes_total) if self.copy_bytes_total else 1.0
            f_photo = (self.photo_done / self.photo_total) if self.photo_total else 1.0
            f_video = ((self.video_done + self.video_pct / 100) / self.video_total) \
                if self.video_total else 1.0
            d["overall_pct"] = round(
                min(100.0, (f_copy * w_copy + f_photo * w_photo + f_video * w_video)
                    / tot_w * 100), 1)
        else:
            d["overall_pct"] = 0.0

        saved = (self.photo_in + self.video_in) - (self.photo_out + self.video_out)
        d["social_in"] = self.photo_in + self.video_in
        d["social_out"] = self.photo_out + self.video_out
        d["social_saved"] = max(0, saved)
        d["log"] = self.log[-200:]
        return d


def plan_summary(files: list[core.MediaFile], pcfg: PhotoCfg, vcfg: VideoCfg,
                 keep_originals: bool = False) -> dict:
    """What the confirm step shows: counts, sizes, predicted social output."""
    photos = [f for f in files if f.kind in (core.KIND_JPEG, core.KIND_RAW)]
    videos = [f for f in files if f.kind == core.KIND_VIDEO]
    raws = [f for f in files if f.kind == core.KIND_RAW]

    orig_bytes = sum(f.size for f in files)
    out = {
        "photos": len(photos), "videos": len(videos), "raws": len(raws),
        "original_bytes": orig_bytes,
        "keep_originals": keep_originals,
        "social_photo_bytes": 0, "social_video_bytes": 0,
        "social_photos": 0, "social_videos": 0,
        "notes": [],
    }

    if pcfg.enabled:
        jpegs = [f for f in files if f.kind == core.KIND_JPEG]
        out["social_photos"] = len(jpegs)
        est = 0
        for f in jpegs:
            # No dimensions until we open it; assume 24MP, the common Sony frame.
            est += photo.estimate_out_size(f.size, (6000, 4000),
                                           pcfg.long_edge, pcfg.quality)
        out["social_photo_bytes"] = est
        if raws and keep_originals:
            out["notes"].append(
                f"{len(raws)} RAW file{'s' if len(raws)!=1 else ''} will be copied "
                f"as-is — RAW isn't a social format.")

    if vcfg.enabled and videos:
        out["social_videos"] = len(videos)
        ps = compress.PRESET_BY_KEY.get(vcfg.preset, compress.PRESET_BY_KEY["reels"])
        if vcfg.mode == "size" and vcfg.target_mb:
            out["social_video_bytes"] = int(vcfg.target_mb * 1024 * 1024 * len(videos))
        else:
            # Assume 4K60-ish source; the real number comes from ffprobe later.
            est = 0
            for f in videos:
                est += int(f.size * 0.12)      # ~8x reduction, typical 4K -> 1080p
            out["social_video_bytes"] = est

    if raws and not keep_originals:
        out["notes"].append(
            f"{len(raws)} RAW file{'s' if len(raws)!=1 else ''} will be skipped — "
            f"RAW can't become a social version, and originals aren't being kept.")

    total = 0
    if keep_originals:
        total += orig_bytes
    total += out["social_photo_bytes"] + out["social_video_bytes"]
    out["total_write_bytes"] = total
    return out


def _social_dir(dest_root: Path, f: core.MediaFile, layout: str,
                keep_originals: bool) -> Path:
    """Social versions sit in a Social/ subfolder next to the originals.

    With no originals being kept there is nothing to sit beside, so they go
    straight into the destination -- otherwise a plain "compress this file"
    would bury its one output in a pointless subfolder.
    """
    orig = core.dest_path_for(f, dest_root, layout)
    return orig.parent / SOCIAL_DIRNAME if keep_originals else orig.parent


def run_import(
    files: list[core.MediaFile],
    dest_root: str,
    layout: str = "by-day",
    keep_originals: bool = False,
    pcfg: PhotoCfg | None = None,
    vcfg: VideoCfg | None = None,
    prog: JobProgress | None = None,
    cancel=lambda: False,
) -> JobProgress:
    p = prog or JobProgress()
    pcfg = pcfg or PhotoCfg()
    vcfg = vcfg or VideoCfg()
    dest = Path(dest_root).expanduser()
    p.dest = str(dest)
    p.started_at = time.time()

    photos = [f for f in files if f.kind == core.KIND_JPEG]
    videos = [f for f in files if f.kind == core.KIND_VIDEO]
    p.photo_total = len(photos) if pcfg.enabled else 0
    p.video_total = len(videos) if vcfg.enabled else 0

    # Where each source file ended up, so phase 2 reads from local disk.
    local: dict[str, str] = {}

    # ---- phase 1: copy originals ------------------------------------------
    if keep_originals:
        p.state = "copying"
        p.phase_label = "Copying originals from the card"
        cp = core.Progress()
        p.copy_total = len(files)
        p.copy_bytes_total = sum(f.size for f in files)

        watch = threading.Event()
        def mirror():
            while not watch.is_set():
                p.copy_done, p.copy_skipped = cp.done_files, cp.skipped_files
                p.copy_bytes_done, p.current = cp.done_bytes, cp.current
                time.sleep(0.15)
        t = threading.Thread(target=mirror, daemon=True); t.start()

        core.copy_files(files, str(dest), layout, verify=False,
                        progress=cp, cancel=cancel)
        watch.set(); t.join(timeout=1)

        p.copy_done, p.copy_skipped = cp.done_files, cp.skipped_files
        p.copy_bytes_done = cp.done_bytes
        p.errors.extend(cp.errors)
        for line in cp.log:
            p.note(line)

        if cp.state == "cancelled":
            p.state = "cancelled"; p.finished_at = time.time(); return p

        for f in files:
            t_ = core.dest_path_for(f, dest, layout)
            if t_.exists():
                local[f.src] = str(t_)
    else:
        p.copy_bytes_total = p.copy_total = 0

    if cancel():
        p.state = "cancelled"; p.finished_at = time.time(); return p

    # ---- phase 2: photos ---------------------------------------------------
    if pcfg.enabled and photos:
        p.state = "photos"
        p.phase_label = f"Resizing {len(photos)} photo{'s' if len(photos)!=1 else ''} for social"
        for f in photos:
            if cancel():
                p.state = "cancelled"; p.finished_at = time.time(); return p
            p.current = f.name
            sdir = _social_dir(dest, f, layout, keep_originals)
            if str(sdir) not in p.social_dirs:
                p.social_dirs.append(str(sdir))
            src = local.get(f.src, f.src)
            r = photo.resize(src, sdir, pcfg.long_edge, pcfg.quality,
                             pcfg.strip_gps, on_exists=pcfg.on_exists)
            if r.ok and not r.skipped:
                p.photo_in += r.src_size
                p.photo_out += r.out_size
                p.note(f"photo  {f.name}  {r.src_wh[0]}×{r.src_wh[1]} → "
                       f"{r.out_wh[0]}×{r.out_wh[1]}  "
                       f"{core.human(r.src_size)} → {core.human(r.out_size)}")
            elif r.skipped:
                p.note(f"photo  {f.name}  skipped ({r.reason})")
            else:
                p.errors.append(f"{f.name}: {r.error}")
                p.note(f"FAILED {f.name}: {r.error}")
            p.photo_done += 1

    # ---- phase 3: videos ---------------------------------------------------
    if vcfg.enabled and videos:
        p.state = "videos"
        for i, f in enumerate(videos, 1):
            if cancel():
                p.state = "cancelled"; p.finished_at = time.time(); return p
            p.current = f.name
            p.video_pct = 0.0
            p.phase_label = f"Compressing video {i} of {len(videos)}"
            sdir = _social_dir(dest, f, layout, keep_originals)
            if str(sdir) not in p.social_dirs:
                p.social_dirs.append(str(sdir))
            src = local.get(f.src, f.src)

            pr = compress.probe(src)
            if not pr.ok:
                p.errors.append(f"{f.name}: {pr.error}")
                p.note(f"FAILED {f.name}: {pr.error}")
                p.video_done += 1
                continue

            pl = compress.make_plan(pr, vcfg.preset, vcfg.mode,
                                    target_mb=vcfg.target_mb or None,
                                    fast=vcfg.fast, tonemap=vcfg.tonemap)
            for w in pl.warnings:
                p.note(f"note   {f.name}: {w}")

            out = compress.out_path_for(src, str(sdir), vcfg.preset,
                                        vcfg.on_exists)
            if vcfg.on_exists == "skip" and out.exists():
                p.note(f"video  {f.name}  skipped (already imported)")
                p.video_done += 1
                continue

            enc = compress.Encode()

            watch = threading.Event()
            def mirror(e=enc):
                while not watch.is_set():
                    d = e.as_dict()
                    p.video_pct = d["overall_pct"]
                    p.video_eta = d["eta_sec"]
                    time.sleep(0.2)
            t = threading.Thread(target=mirror, daemon=True); t.start()

            compress.encode(pr, pl, out, enc, cancel)
            watch.set(); t.join(timeout=1)

            if enc.state == "cancelled":
                p.state = "cancelled"; p.finished_at = time.time(); return p
            if enc.state == "done":
                p.video_in += enc.src_size
                p.video_out += enc.out_size
                p.note(f"video  {f.name}  {pr.display_w}×{pr.display_h} → "
                       f"{pl.out_w}×{pl.out_h}  "
                       f"{core.human(enc.src_size)} → {core.human(enc.out_size)}")
            else:
                p.errors.append(f"{f.name}: {enc.error}")
                p.note(f"FAILED {f.name}: {enc.error}")
            p.video_pct = 100.0
            p.video_done += 1

    p.current = ""
    p.video_eta = None
    p.phase_label = ""
    p.state = "error" if p.errors else "done"
    p.finished_at = time.time()
    return p
