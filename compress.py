"""Video compression for social upload.

Wraps ffmpeg. Two ways to drive it:

  quality mode  -- pick a CRF, size falls where it falls (with a bitrate ceiling)
  size mode     -- name a target size, two-pass VBR hits it

Never overwrites the source. Output always lands beside it (or wherever asked)
under a new name.
"""

from __future__ import annotations

import json
import math
import os
import re
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path

VIDEO_EXTS = {".mp4", ".mov", ".mts", ".m2ts", ".avi", ".mkv", ".m4v"}


def have_ffmpeg() -> bool:
    return bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))


# ------------------------------------------------------------------- presets
#
# Platform limits move around constantly -- these are conservative values
# meant to keep an upload from being rejected, not gospel.

@dataclass
class Preset:
    key: str
    label: str
    note: str
    long_edge: int          # cap on the longer dimension
    crf: int
    maxrate_kbps: int
    audio_kbps: int
    size_cap_mb: int | None = None      # hard platform ceiling, if any
    duration_cap_s: int | None = None   # flag clips longer than this
    fps_cap: int = 60


PRESETS: list[Preset] = [
    Preset("reels", "Reels / TikTok / Shorts",
           "Vertical short-form. TikTok caps mobile uploads near 290 MB.",
           1920, 21, 12000, 128, size_cap_mb=280, duration_cap_s=180),
    Preset("feed", "Instagram Feed / Facebook",
           "Standard feed post. Generous limits, quality-first.",
           1920, 21, 12000, 128, size_cap_mb=4000),
    Preset("youtube", "YouTube",
           "YouTube re-encodes anyway; feed it a clean high-bitrate 1080p.",
           1920, 20, 16000, 192),
    Preset("x", "X / Twitter",
           "512 MB and 2:20 on free accounts; Premium allows far more.",
           1920, 23, 8000, 128, size_cap_mb=500, duration_cap_s=140),
    Preset("small", "Messaging / email",
           "720p, aggressive. For when it has to be small above all.",
           1280, 26, 4000, 96, size_cap_mb=100),
    Preset("custom", "Custom", "Set everything yourself.",
           1920, 21, 12000, 128),
]

PRESET_BY_KEY = {p.key: p for p in PRESETS}

# Rough x264 bits-per-pixel at a given CRF, medium preset, typical content.
# Only used to predict output size before encoding -- deliberately a range.
_BPP = {16: 0.20, 17: 0.175, 18: 0.15, 19: 0.13, 20: 0.115, 21: 0.10,
        22: 0.088, 23: 0.075, 24: 0.065, 25: 0.055, 26: 0.045,
        27: 0.038, 28: 0.032, 29: 0.027, 30: 0.023}


# --------------------------------------------------------------------- probe

@dataclass
class Probe:
    path: str
    name: str
    ok: bool
    error: str = ""
    size: int = 0
    duration: float = 0.0
    width: int = 0
    height: int = 0
    fps: float = 0.0
    vcodec: str = ""
    acodec: str = ""
    achannels: int = 0
    bitrate: int = 0            # bits/sec, whole file
    color_transfer: str = ""
    rotation: int = 0
    is_hdr: bool = False
    hdr_kind: str = ""          # "HLG" | "PQ" | ""

    @property
    def display_w(self) -> int:
        return self.height if self.rotation in (90, 270) else self.width

    @property
    def display_h(self) -> int:
        return self.width if self.rotation in (90, 270) else self.height


def _frac(s: str) -> float:
    try:
        if "/" in s:
            a, b = s.split("/")
            return float(a) / float(b) if float(b) else 0.0
        return float(s)
    except (ValueError, ZeroDivisionError):
        return 0.0


def probe(path: str) -> Probe:
    p = Path(path)
    pr = Probe(path=str(p), name=p.name, ok=False)
    if not p.is_file():
        pr.error = "File not found."
        return pr
    if not have_ffmpeg():
        pr.error = "ffmpeg is not installed."
        return pr

    try:
        out = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json",
             "-show_format", "-show_streams", str(p)],
            capture_output=True, text=True, timeout=120,
        )
        data = json.loads(out.stdout or "{}")
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError) as e:
        pr.error = f"Could not read the file: {e}"
        return pr

    streams = data.get("streams") or []
    fmt = data.get("format") or {}
    v = next((s for s in streams if s.get("codec_type") == "video"), None)
    a = next((s for s in streams if s.get("codec_type") == "audio"), None)
    if not v:
        pr.error = "No video track in this file."
        return pr

    try:
        pr.size = int(fmt.get("size") or p.stat().st_size)
    except (ValueError, OSError):
        pr.size = 0
    pr.duration = float(fmt.get("duration") or v.get("duration") or 0)
    pr.width = int(v.get("width") or 0)
    pr.height = int(v.get("height") or 0)
    pr.fps = _frac(v.get("avg_frame_rate") or v.get("r_frame_rate") or "0")
    pr.vcodec = v.get("codec_name") or ""
    pr.bitrate = int(fmt.get("bit_rate") or 0)
    pr.color_transfer = (v.get("color_transfer") or "").lower()

    if a:
        pr.acodec = a.get("codec_name") or ""
        pr.achannels = int(a.get("channels") or 0)

    # Rotation can live in a side-data block or the stream tags.
    for sd in v.get("side_data_list") or []:
        if "rotation" in sd:
            try:
                pr.rotation = int(abs(float(sd["rotation"]))) % 360
            except (TypeError, ValueError):
                pass
    if not pr.rotation:
        try:
            pr.rotation = int(abs(float((v.get("tags") or {}).get("rotate", 0)))) % 360
        except (TypeError, ValueError):
            pr.rotation = 0

    if pr.color_transfer in ("arib-std-b67",):
        pr.is_hdr, pr.hdr_kind = True, "HLG"
    elif pr.color_transfer in ("smpte2084",):
        pr.is_hdr, pr.hdr_kind = True, "PQ"

    if pr.duration <= 0 or pr.width <= 0:
        pr.error = "This file reports no duration or resolution."
        return pr

    pr.ok = True
    return pr


# ---------------------------------------------------------------------- plan

def _even(n: int) -> int:
    return max(2, int(n) // 2 * 2)


def target_size(pr: Probe, long_edge: int) -> tuple[int, int]:
    """Scale to fit long_edge, preserving aspect. Never upscales."""
    w, h = pr.display_w, pr.display_h
    if w <= 0 or h <= 0:
        return 0, 0
    longest = max(w, h)
    if longest <= long_edge:
        return _even(w), _even(h)
    f = long_edge / longest
    return _even(round(w * f)), _even(round(h * f))


@dataclass
class Plan:
    out_w: int = 0
    out_h: int = 0
    out_fps: float = 0.0
    mode: str = "quality"
    crf: int = 21
    maxrate_kbps: int = 12000
    video_kbps: int = 0          # size mode only
    audio_kbps: int = 128
    est_low: int = 0             # bytes
    est_high: int = 0
    est_exact: int = 0           # size mode: the number we're aiming at
    two_pass: bool = False
    tonemap: bool = False
    encoder: str = "libx264"
    warnings: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)


def make_plan(
    pr: Probe,
    preset_key: str = "reels",
    mode: str = "quality",
    crf: int | None = None,
    long_edge: int | None = None,
    target_mb: float | None = None,
    audio_kbps: int | None = None,
    fast: bool = False,
    tonemap: bool | None = None,
) -> Plan:
    ps = PRESET_BY_KEY.get(preset_key, PRESET_BY_KEY["reels"])
    pl = Plan()
    pl.mode = mode
    pl.crf = ps.crf if crf is None else int(crf)
    pl.maxrate_kbps = ps.maxrate_kbps
    pl.audio_kbps = ps.audio_kbps if audio_kbps is None else int(audio_kbps)
    pl.encoder = "h264_videotoolbox" if fast else "libx264"

    le = ps.long_edge if long_edge is None else int(long_edge)
    pl.out_w, pl.out_h = target_size(pr, le)

    pl.out_fps = pr.fps
    if ps.fps_cap and pr.fps > ps.fps_cap + 0.5:
        pl.out_fps = float(ps.fps_cap)
        pl.notes.append(f"Frame rate capped at {ps.fps_cap} fps (source is {pr.fps:.0f}).")

    pl.tonemap = pr.is_hdr if tonemap is None else bool(tonemap)

    pixels_per_sec = pl.out_w * pl.out_h * max(pl.out_fps, 1)

    if mode == "size" and target_mb:
        pl.two_pass = not fast          # hardware encoder can't do a real 2-pass
        total_bits = target_mb * 1024 * 1024 * 8 * 0.97      # container overhead
        v_kbps = int((total_bits / max(pr.duration, 1) - pl.audio_kbps * 1000) / 1000)
        pl.video_kbps = max(200, v_kbps)
        pl.est_exact = int(target_mb * 1024 * 1024)
        if pl.video_kbps <= 500:
            pl.warnings.append(
                f"That target needs only {pl.video_kbps} kbps of video — it will look rough. "
                f"Try a smaller resolution or a larger size.")
    else:
        bpp = _BPP.get(pl.crf, 0.10)
        est_kbps = min(bpp * pixels_per_sec / 1000, pl.maxrate_kbps)
        total_kbps = est_kbps + pl.audio_kbps
        mid = total_kbps * 1000 * pr.duration / 8
        # Wide on purpose: real bitrate swings hard with grain and motion.
        pl.est_low, pl.est_high = int(mid * 0.45), int(mid * 1.55)

    # ---- advisories --------------------------------------------------------
    if ps.duration_cap_s and pr.duration > ps.duration_cap_s:
        m, s = divmod(int(pr.duration), 60)
        cm, cs = divmod(ps.duration_cap_s, 60)
        pl.warnings.append(
            f"This clip is {m}:{s:02d}, over {ps.label}'s {cm}:{cs:02d} limit. "
            f"Compressing won't fix that — you'd need to trim it.")

    cap = ps.size_cap_mb
    if cap:
        likely = pl.est_exact or pl.est_high
        if likely > cap * 1024 * 1024:
            pl.warnings.append(
                f"Estimated output may exceed {ps.label}'s ~{cap} MB ceiling. "
                f"Switch to “Fit under a size” if it has to be guaranteed.")

    if pr.is_hdr and pl.tonemap:
        pl.notes.append(
            f"Source is {pr.hdr_kind} HDR. Converting to standard BT.709 so it "
            f"doesn't look washed out after upload.")
    elif pr.is_hdr:
        pl.warnings.append(
            f"Source is {pr.hdr_kind} HDR and tone mapping is off. Most social "
            f"platforms will show this desaturated or too dark.")

    if fast:
        pl.notes.append("Hardware encoder: much faster, slightly larger for the same quality.")

    if max(pr.display_w, pr.display_h) <= le:
        pl.notes.append(f"Already {pr.display_w}×{pr.display_h}; not upscaling.")

    return pl


# -------------------------------------------------------------------- encode

def out_path_for(src: str, dest_dir: str | None, preset_key: str,
                 on_exists: str = "rename") -> Path:
    """Where the compressed copy belongs. See photo.out_path_for for the
    on_exists modes; they mean the same thing here."""
    s = Path(src)
    d = Path(dest_dir).expanduser() if dest_dir else s.parent
    base = f"{s.stem}-{preset_key}.mp4"
    out = d / base
    if on_exists != "rename":
        return out
    n = 1
    while out.exists():
        out = d / f"{s.stem}-{preset_key}-{n}.mp4"
        n += 1
    return out


def _vf_chain(pr: Probe, pl: Plan) -> str:
    parts = []
    if pl.tonemap:
        # No zscale in this ffmpeg build, so use the colorspace filter to bring
        # HLG/PQ down to BT.709. Less precise than a zscale+tonemap chain but it
        # works everywhere and beats shipping washed-out HDR to a social feed.
        parts.append("colorspace=all=bt709:iall=bt2020:fast=1")
    if (pl.out_w, pl.out_h) != (pr.display_w, pr.display_h):
        parts.append(f"scale={pl.out_w}:{pl.out_h}:flags=lanczos")
    if pl.out_fps and pr.fps and pl.out_fps < pr.fps - 0.5:
        parts.append(f"fps={pl.out_fps:g}")
    parts.append("format=yuv420p")
    return ",".join(parts)


def build_cmd(pr: Probe, pl: Plan, out: Path, pass_no: int = 0,
              passlog: str | None = None) -> list[str]:
    c = ["ffmpeg", "-hide_banner", "-nostdin", "-y", "-i", pr.path,
         "-map", "0:v:0", "-map", "0:a:0?"]

    c += ["-vf", _vf_chain(pr, pl)]

    if pl.encoder == "h264_videotoolbox":
        c += ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-allow_sw", "1"]
        if pl.mode == "size":
            c += ["-b:v", f"{pl.video_kbps}k"]
        else:
            # VideoToolbox has no CRF; -q:v is its quality scale (1-100).
            c += ["-q:v", str(max(1, min(100, 100 - pl.crf * 3)))]
            c += ["-maxrate", f"{pl.maxrate_kbps}k", "-bufsize", f"{pl.maxrate_kbps*2}k"]
    else:
        c += ["-c:v", "libx264", "-preset", "medium", "-profile:v", "high", "-level", "4.2"]
        if pl.mode == "size":
            c += ["-b:v", f"{pl.video_kbps}k",
                  "-maxrate", f"{int(pl.video_kbps*1.5)}k",
                  "-bufsize", f"{pl.video_kbps*2}k"]
        else:
            c += ["-crf", str(pl.crf),
                  "-maxrate", f"{pl.maxrate_kbps}k",
                  "-bufsize", f"{pl.maxrate_kbps*2}k"]

    if pass_no in (1, 2):
        c += ["-pass", str(pass_no)]
        if passlog:
            c += ["-passlogfile", passlog]

    if pass_no == 1:
        c += ["-an", "-f", "mp4", os.devnull]
    else:
        if pr.acodec:
            c += ["-c:a", "aac", "-b:a", f"{pl.audio_kbps}k", "-ac", "2", "-ar", "48000"]
        else:
            c += ["-an"]
        c += ["-movflags", "+faststart", str(out)]

    c += ["-progress", "pipe:1", "-nostats"]
    return c


@dataclass
class Encode:
    state: str = "idle"      # idle | encoding | done | error | cancelled
    pass_no: int = 0
    passes: int = 1
    pct: float = 0.0
    fps: float = 0.0
    speed: float = 0.0
    out_time: float = 0.0
    duration: float = 0.0
    src: str = ""
    src_size: int = 0
    out: str = ""
    out_size: int = 0
    started_at: float = 0.0
    finished_at: float = 0.0
    error: str = ""
    tail: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        d = asdict(self)
        el = (self.finished_at or time.time()) - self.started_at if self.started_at else 0
        d["elapsed"] = round(el, 1)
        overall = (self.pass_no - 1 + self.pct / 100) / self.passes * 100 if self.passes else self.pct
        d["overall_pct"] = round(max(0.0, min(100.0, overall)), 1)
        if self.speed > 0 and self.duration > 0:
            remain_media = self.duration * self.passes - (
                (self.pass_no - 1) * self.duration + self.out_time)
            d["eta_sec"] = max(0, round(remain_media / self.speed))
        else:
            d["eta_sec"] = None
        if self.out_size and self.src_size:
            d["ratio"] = round(self.src_size / self.out_size, 1)
        else:
            d["ratio"] = None
        d["tail"] = self.tail[-40:]
        return d


_PROG_RE = re.compile(r"^(\w+)=(.*)$")


def _run_pass(cmd: list[str], enc: Encode, cancel, duration: float) -> int:
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, bufsize=1)
    except OSError as e:
        enc.error = f"Could not start ffmpeg: {e}"
        return -1

    # ffmpeg writes real errors to stderr; keep the last lines for diagnosis.
    def drain():
        for line in proc.stderr:
            line = line.rstrip()
            if line:
                enc.tail.append(line)
                del enc.tail[:-60]
    t = threading.Thread(target=drain, daemon=True)
    t.start()

    for line in proc.stdout:
        if cancel():
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            return -2
        m = _PROG_RE.match(line.strip())
        if not m:
            continue
        k, v = m.group(1), m.group(2)
        if k == "out_time_us":
            try:
                enc.out_time = int(v) / 1_000_000
                if duration > 0:
                    enc.pct = min(100.0, enc.out_time / duration * 100)
            except ValueError:
                pass
        elif k == "fps":
            try: enc.fps = float(v)
            except ValueError: pass
        elif k == "speed":
            try: enc.speed = float(v.rstrip("x") or 0)
            except ValueError: pass

    proc.wait()
    t.join(timeout=2)
    return proc.returncode


def encode(pr: Probe, pl: Plan, out: Path, enc: Encode | None = None,
           cancel=lambda: False) -> Encode:
    e = enc or Encode()
    e.state = "encoding"
    e.src, e.src_size = pr.path, pr.size
    e.out = str(out)
    e.duration = pr.duration
    e.passes = 2 if pl.two_pass else 1
    e.started_at = time.time()

    try:
        out.parent.mkdir(parents=True, exist_ok=True)
    except OSError as ex:
        e.state, e.error = "error", f"Cannot write to that folder: {ex}"
        e.finished_at = time.time()
        return e

    if Path(pr.path).resolve() == out.resolve():
        e.state, e.error = "error", "Output would overwrite the source."
        e.finished_at = time.time()
        return e

    passlog = str(out.with_suffix("")) + ".ffpass"
    try:
        for n in ([1, 2] if pl.two_pass else [0]):
            e.pass_no = max(1, n)
            e.pct = 0.0
            rc = _run_pass(build_cmd(pr, pl, out, n, passlog), e, cancel, pr.duration)
            if rc == -2:
                e.state = "cancelled"
                out.unlink(missing_ok=True)
                e.finished_at = time.time()
                return e
            if rc != 0:
                e.state = "error"
                detail = next((l for l in reversed(e.tail)
                               if "error" in l.lower() or "invalid" in l.lower()), "")
                e.error = detail or f"ffmpeg exited with code {rc}."
                out.unlink(missing_ok=True)
                e.finished_at = time.time()
                return e
    finally:
        for junk in Path(passlog).parent.glob(Path(passlog).name + "*"):
            junk.unlink(missing_ok=True)

    if not out.is_file() or out.stat().st_size == 0:
        e.state, e.error = "error", "ffmpeg finished but produced no output."
        e.finished_at = time.time()
        return e

    e.out_size = out.stat().st_size
    e.pct = 100.0
    e.state = "done"
    e.finished_at = time.time()
    return e


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"
