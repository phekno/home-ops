#!/usr/bin/env python3
"""Import queue for beets, driven by slskd's DownloadDirectoryComplete webhook.

slskd knows when an album has finished transferring; mtime heuristics only
guess at it. This turns that event into an immediate, targeted import.

Every import runs on a single worker thread. beets' library is a SQLite file on
a ReadWriteOnce volume, so concurrent imports would contend on both.
"""
import json
import logging
import os
import queue
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MUSIC = Path("/music")
INCOMING = MUSIC / "_incoming"
PORT = int(os.environ.get("WORKER_PORT", "8337"))
# A sweep is the backstop for folders the webhook never fired for, which may
# still be arriving - so it keeps the age guard the webhook path does not need.
SWEEP_MIN_AGE = int(os.environ.get("SWEEP_MIN_AGE_SECONDS", "1800"))

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("beets-worker")

jobs: "queue.Queue[Path]" = queue.Queue()
seen: "set[str]" = set()
seen_lock = threading.Lock()


def safe_target(raw: str) -> Path | None:
    """Resolve an untrusted path and confirm it stays inside _incoming."""
    try:
        target = Path(raw).resolve()
    except (OSError, ValueError):
        return None
    if not target.is_relative_to(INCOMING.resolve()):
        log.warning("rejected path outside %s: %r", INCOMING, raw)
        return None
    if not target.exists():
        log.warning("rejected non-existent path: %r", raw)
        return None
    return target


def enqueue(target: Path) -> bool:
    key = str(target)
    with seen_lock:
        if key in seen:
            return False
        seen.add(key)
    jobs.put(target)
    return True


def run_import(target: Path) -> None:
    log.info("importing %s", target)
    proc = subprocess.run(
        ["beet", "import", "-q", str(target)],
        capture_output=True,
        text=True,
        timeout=3600,
    )
    for line in (proc.stdout or "").splitlines():
        log.info("beet: %s", line)
    for line in (proc.stderr or "").splitlines():
        log.warning("beet: %s", line)
    if proc.returncode != 0:
        log.error("beet exited %s for %s", proc.returncode, target)
    elif target.exists():
        # move: yes means a surviving folder is beets declining to guess.
        log.info("left in place (no confident match): %s", target)
    else:
        log.info("imported and filed: %s", target)


def consume() -> None:
    while True:
        target = jobs.get()
        try:
            run_import(target)
        except subprocess.TimeoutExpired:
            log.error("beet timed out for %s", target)
        except Exception:
            log.exception("import failed for %s", target)
        finally:
            with seen_lock:
                seen.discard(str(target))
            jobs.task_done()


def sweep() -> int:
    if not INCOMING.exists():
        return 0
    cutoff = time.time() - SWEEP_MIN_AGE
    count = 0
    for entry in sorted(INCOMING.iterdir()):
        try:
            if entry.stat().st_mtime > cutoff:
                continue
        except OSError:
            continue
        if enqueue(entry):
            count += 1
    return count


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.reply(200, {"ok": True, "queued": jobs.qsize()})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""

        if self.path == "/event":
            try:
                event = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return self.reply(400, {"error": "invalid json"})
            # slskd serialises as camelCase; accept either to survive a rename.
            name = event.get("localDirectoryName") or event.get(
                "LocalDirectoryName"
            )
            if not name:
                return self.reply(400, {"error": "no localDirectoryName"})
            target = safe_target(name)
            if target is None:
                return self.reply(400, {"error": "invalid path"})
            queued = enqueue(target)
            log.info("event for %s (queued=%s)", target, queued)
            return self.reply(202, {"queued": queued, "path": str(target)})

        if self.path == "/sweep":
            n = sweep()
            log.info("sweep queued %d director(ies)", n)
            return self.reply(202, {"queued": n})

        if self.path == "/library":
            # Whole-library normalisation; runs on the same single thread, so it
            # cannot collide with an incoming import.
            if enqueue(MUSIC):
                log.info("queued full library import")
                return self.reply(202, {"queued": True})
            return self.reply(409, {"error": "already queued"})

        self.reply(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        log.info("%s - %s", self.address_string(), fmt % args)


def main() -> None:
    threading.Thread(target=consume, daemon=True).start()
    log.info("listening on :%d (sweep min age %ds)", PORT, SWEEP_MIN_AGE)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
