"""SonyGrab: local web UI for pulling media off a Sony camera card
and making social-ready versions of it.

Loopback-only HTTP server, stdlib only. Opens the UI in your browser.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import fcntl
import threading
import time
import webbrowser
from dataclasses import asdict
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

import compress
import core
import photo
import pipeline

HERE = Path(__file__).resolve().parent
TOKEN = secrets.token_urlsafe(16)

LOCK = threading.Lock()
STATE = {
    "scan": {},                       # card path -> list[MediaFile]
    "job": pipeline.JobProgress(),
    "cancel": False,
    "last_seen": time.time(),         # last browser contact
    "quit": False,
}

# Launched from the .app there is no terminal to Ctrl-C, so the server retires
# on its own once the browser has been gone a while and nothing is running.
IDLE_TIMEOUT = 15 * 60
PIDFILE = Path.home() / ".sonygrab.pid"
LOCKFILE = Path.home() / ".sonygrab.lock"
_lock_handle = None          # held open for the process lifetime


def _set_cancel(v: bool) -> None:
    with LOCK:
        STATE["cancel"] = v


def _cancelled() -> bool:
    with LOCK:
        return STATE["cancel"]


def _busy() -> bool:
    with LOCK:
        return STATE["job"].state in ("copying", "photos", "videos")


def _on_exists(d: dict) -> str:
    v = d.get("on_exists")
    return v if v in ("skip", "replace", "rename") else "skip"


def _cfgs(body: dict) -> tuple[pipeline.PhotoCfg, pipeline.VideoCfg, bool]:
    p = body.get("photo") or {}
    v = body.get("video") or {}
    pcfg = pipeline.PhotoCfg(
        enabled=bool(p.get("enabled", True)),
        long_edge=int(p.get("long_edge", 2560) or 0),
        quality=max(40, min(97, int(p.get("quality", 85)))),
        strip_gps=bool(p.get("strip_gps", True)),
        on_exists=_on_exists(p),
    )
    vcfg = pipeline.VideoCfg(
        enabled=bool(v.get("enabled", True)),
        preset=v.get("preset") or "reels",
        mode=v.get("mode") or "quality",
        target_mb=float(v.get("target_mb") or 0),
        fast=bool(v.get("fast")),
        tonemap=v.get("tonemap") if v.get("tonemap") in (True, False) else None,
        on_exists=_on_exists(v),
    )
    return pcfg, vcfg, bool(body.get("keep_originals", False))


class Handler(BaseHTTPRequestHandler):
    server_version = "SonyGrab"

    def log_message(self, fmt, *a):
        pass

    # ------------------------------------------------------------- plumbing

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj, code: int = 200) -> None:
        self._send(code, json.dumps(obj, default=str).encode(), "application/json")

    def _authed(self) -> bool:
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            return False
        if self.headers.get("X-Token") != TOKEN:
            return False
        with LOCK:
            STATE["last_seen"] = time.time()
        return True

    def _body(self) -> dict:
        try:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or "{}")
        except (ValueError, json.JSONDecodeError):
            return {}

    # ----------------------------------------------------------------- GET

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/":
            html = (HERE / "ui.html").read_text(encoding="utf-8")
            return self._send(200, html.replace("__TOKEN__", TOKEN).encode(),
                              "text/html; charset=utf-8")

        if not self._authed():
            return self._json({"error": "unauthorized"}, 403)

        if path == "/api/cards":
            return self._json({"cards": [asdict(c) for c in core.detect_cards()]})

        if path == "/api/progress":
            with LOCK:
                return self._json(STATE["job"].as_dict())

        if path == "/api/ping":
            return self._json({"ok": True, "busy": _busy()})

        if path == "/api/defaults":
            return self._json({
                "home": str(Path.home()),
                "pictures": str(Path.home() / "Pictures"),
                "desktop": str(Path.home() / "Desktop"),
                "has_exiftool": bool(shutil.which("exiftool")),
                "has_ffmpeg": compress.have_ffmpeg(),
                "has_pillow": photo.HAVE_PIL,
                "video_presets": [asdict(p) for p in compress.PRESETS],
                "photo_sizes": [{"key": k, "label": v[0], "long_edge": v[1]}
                                for k, v in photo.SIZE_PRESETS.items()],
            })

        return self._json({"error": "not found"}, 404)

    # ---------------------------------------------------------------- POST

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._authed():
            return self._json({"error": "unauthorized"}, 403)
        body = self._body()

        # ---- card scanning ------------------------------------------------
        if path == "/api/scan":
            card = body.get("card") or ""
            if not Path(card).is_dir():
                return self._json({"error": "That card is not mounted any more."}, 400)
            files = core.scan_card(card)
            with LOCK:
                STATE["scan"][card] = files
            return self._json({
                "files": [asdict(f) for f in files],
                "days": core.day_summary(files),
            })

        # ---- confirm step -------------------------------------------------
        if path == "/api/plan":
            sel = self._selection(body)
            if isinstance(sel, tuple):
                return self._json({"error": sel[1]}, 400)
            pcfg, vcfg, keep = _cfgs(body)
            return self._json(pipeline.plan_summary(sel, pcfg, vcfg, keep))

        # ---- run the import ----------------------------------------------
        if path == "/api/import":
            if _busy():
                return self._json({"error": "Something is already running."}, 409)
            sel = self._selection(body)
            if isinstance(sel, tuple):
                return self._json({"error": sel[1]}, 400)
            dest = (body.get("dest") or "").strip()
            if not dest:
                return self._json({"error": "Pick a destination folder."}, 400)
            pcfg, vcfg, keep = _cfgs(body)
            if not keep and not pcfg.enabled and not vcfg.enabled:
                return self._json({"error": "Nothing to do — everything is switched off."}, 400)

            layout = body.get("layout") or "by-day"
            job = pipeline.JobProgress()
            with LOCK:
                STATE["job"] = job
                STATE["cancel"] = False
            threading.Thread(
                target=lambda: pipeline.run_import(
                    sel, dest, layout, keep, pcfg, vcfg, job, _cancelled),
                daemon=True).start()
            return self._json({"started": True, "count": len(sel)})

        # ---- standalone: compress a video already on disk -----------------
        if path == "/api/probe":
            pr = compress.probe(body.get("path") or "")
            d = asdict(pr)
            d["display_w"], d["display_h"] = pr.display_w, pr.display_h
            if pr.ok:
                plans = {}
                for ps in compress.PRESETS:
                    if ps.key == "custom":
                        continue
                    pl = compress.make_plan(pr, ps.key, mode="quality")
                    plans[ps.key] = asdict(pl)
                d["plans"] = plans
            return self._json(d)

        if path == "/api/compress":
            if _busy():
                return self._json({"error": "Something is already running."}, 409)
            src = (body.get("path") or "").strip()
            pr = compress.probe(src)
            if not pr.ok:
                return self._json({"error": pr.error}, 400)
            dest = (body.get("dest") or "").strip() or str(Path(src).parent)
            _, vcfg, _ = _cfgs(body)
            vcfg.enabled = True
            vcfg.on_exists = "rename"

            # Reuse the import pipeline: one video, no copy, no photo phase.
            mf = core.MediaFile(
                src=src, name=Path(src).name, kind=core.KIND_VIDEO, size=pr.size,
                shot_at="", date_source="n/a", month="", day="", rel_dir="",
            )
            job = pipeline.JobProgress()
            with LOCK:
                STATE["job"] = job
                STATE["cancel"] = False
            threading.Thread(
                target=lambda: pipeline.run_import(
                    [mf], dest, "flat", False,
                    pipeline.PhotoCfg(enabled=False), vcfg, job, _cancelled),
                daemon=True).start()
            return self._json({"started": True})

        # ---- misc ----------------------------------------------------------
        if path == "/api/cancel":
            _set_cancel(True)
            return self._json({"cancelling": True})

        if path == "/api/quit":
            _set_cancel(True)
            with LOCK:
                STATE["quit"] = True
            return self._json({"quitting": True})

        if path == "/api/reveal":
            target = body.get("path") or ""
            if Path(target).exists():
                subprocess.run(["open", "-R", target], capture_output=True)
                return self._json({"ok": True})
            return self._json({"error": "Path not found."}, 400)

        if path in ("/api/browse", "/api/browse_file"):
            wants_file = path.endswith("_file")
            prompt = "Choose a video" if wants_file else "Choose destination folder"
            what = ("choose file with prompt \"%s\" of type "
                    "{\"public.movie\",\"mp4\",\"mov\",\"mts\",\"m4v\"}" % prompt) \
                if wants_file else f'choose folder with prompt "{prompt}"'
            script = f'try\n  set f to {what}\n  POSIX path of f\non error\n  ""\nend try'
            try:
                out = subprocess.run(["osascript", "-e", script],
                                     capture_output=True, text=True, timeout=300)
                return self._json({"path": out.stdout.strip()})
            except (OSError, subprocess.SubprocessError) as e:
                return self._json({"error": str(e)}, 500)

        return self._json({"error": "not found"}, 404)

    # ------------------------------------------------------------- helpers

    def _selection(self, body: dict):
        """Resolve {card, days, kinds} into MediaFiles, or (None, msg)."""
        card = body.get("card") or ""
        days = set(body.get("days") or [])
        kinds = set(body.get("kinds") or [])
        with LOCK:
            files = STATE["scan"].get(card)
        if files is None:
            return (None, "Scan the card first.")
        sel = [f for f in files if f.day in days and f.kind in kinds]
        if not sel:
            return (None, "Nothing matches that selection.")
        return sel


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _reaper(httpd) -> None:
    """Shut down when told to, or after a long idle spell with nothing running."""
    while True:
        time.sleep(2)
        with LOCK:
            quit_now = STATE["quit"]
            idle = time.time() - STATE["last_seen"]
        if quit_now or (idle > IDLE_TIMEOUT and not _busy()):
            _set_cancel(True)
            threading.Thread(target=httpd.shutdown, daemon=True).start()
            return


def _claim_singleton() -> str | None:
    """Take an exclusive lock, or return the running instance's URL.

    A plain "is that pid alive?" check races: macOS can start the launcher twice
    in quick succession (LaunchServices relaunches an app whose executable exits
    immediately), and both copies would see no pidfile and both bind a port.
    flock is atomic, so exactly one instance can ever win.
    """
    global _lock_handle
    try:
        fh = open(LOCKFILE, "a+")
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Someone else holds it. Give them a moment to publish their URL.
        for _ in range(40):
            try:
                url = PIDFILE.read_text().split("\n", 1)[1].strip()
                if url:
                    return url
            except (OSError, IndexError):
                pass
            time.sleep(0.1)
        return "running"          # alive, but URL not readable
    _lock_handle = fh             # keep the fd open; closing releases the lock
    return None


def main() -> None:
    existing = _claim_singleton()
    if existing and "--force" not in sys.argv:
        print(f"\n  SonyGrab is already running.\n  {existing}\n", flush=True)
        if "--no-open" not in sys.argv and existing.startswith("http"):
            webbrowser.open(existing)
        return

    port = _free_port()
    httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/?t={TOKEN}"

    print("\n  SonyGrab", flush=True)
    print(f"  {url}\n", flush=True)
    print("  The card is only ever read from — nothing is deleted or changed on it.", flush=True)
    print("  Quit with the button in the page, or Ctrl-C if you started it "
          "from a terminal.\n", flush=True)

    try:
        PIDFILE.write_text(f"{os.getpid()}\n{url}\n")
    except OSError:
        pass

    threading.Thread(target=_reaper, args=(httpd,), daemon=True).start()

    if "--no-open" not in sys.argv:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        _set_cancel(True)
        try:
            if PIDFILE.exists() and PIDFILE.read_text().startswith(str(os.getpid())):
                PIDFILE.unlink()
        except OSError:
            pass
        print("\n  Stopped.\n", flush=True)


if __name__ == "__main__":
    main()
