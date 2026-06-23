#!/usr/bin/env python3
"""
backup-engine.py — Multi-backend backup engine: S3, FTP, SFTP.

Resume-capable via SQLite state index. Parallel workers per backend.
Incremental: only uploads files whose hash (mtime+size) changed.
Optional sync-delete: removes remote files absent from source.

Called by backup-tools.sh via env vars — do not invoke directly.

Config env vars (common):
  BACKUP_TYPE         s3 | ftp | sftp
  BACKUP_SOURCE       /absolute/source/path
  BACKUP_DELETE       0 | 1  (delete remote files not in source)
  BACKUP_MAX_WORKERS  parallel threads (default: 10 S3/SFTP, 4 FTP)
  BACKUP_STATE_DIR    SQLite state path (default: ~/.local/share/wanforge-scripts/backup-state/<name>)
  BACKUP_LOG_FILE     append structured log here (optional)
  BACKUP_PROFILE      profile name (for display/log)

  S3:   BACKUP_S3_ENDPOINT, BACKUP_S3_ACCESS_KEY, BACKUP_S3_SECRET_KEY,
        BACKUP_S3_BUCKET, BACKUP_S3_PREFIX
        BACKUP_RETENTION_DAYS (cleanup old dated dirs, default 0=off)
        BACKUP_CLEANUP_TARGET (folder for cleanup, default "databases")

  FTP:  BACKUP_FTP_HOST, BACKUP_FTP_PORT, BACKUP_FTP_USER, BACKUP_FTP_PASS,
        BACKUP_FTP_DEST, BACKUP_FTP_SSL (off|explicit|implicit)

  SFTP: BACKUP_SFTP_HOST, BACKUP_SFTP_PORT, BACKUP_SFTP_USER,
        BACKUP_SFTP_KEY (path to private key, or blank for agent/password),
        BACKUP_SFTP_PASS (password auth if no key), BACKUP_SFTP_DEST

Args:
  --dry-run     simulate only, no uploads/deletes
  --force       re-upload all files (ignore uploaded status in DB)
  --skip-scan   skip file scan, retry pending from last run only

Version: 1.0.0
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (c) 2026 Sugeng Sulistiyawan
"""

import argparse
import ftplib
import json
import logging
import mimetypes
import os
import re
import signal
import sqlite3
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path

# ── env config ────────────────────────────────────────────────────────────────

TYPE          = os.environ.get("BACKUP_TYPE", "s3").lower()
SOURCE        = Path(os.environ.get("BACKUP_SOURCE", ""))
DELETE        = os.environ.get("BACKUP_DELETE", "0") == "1"
PROFILE       = os.environ.get("BACKUP_PROFILE", "backup")
LOG_FILE_PATH = os.environ.get("BACKUP_LOG_FILE", "")

_home = Path.home()
_default_state = _home / ".local/share/wanforge-scripts/backup-state" / PROFILE
STATE_DIR = Path(os.environ.get("BACKUP_STATE_DIR", str(_default_state)))
DB_PATH   = STATE_DIR / "index.db"

# S3
S3_ENDPOINT   = os.environ.get("BACKUP_S3_ENDPOINT", "")
S3_ACCESS_KEY = os.environ.get("BACKUP_S3_ACCESS_KEY", "")
S3_SECRET_KEY = os.environ.get("BACKUP_S3_SECRET_KEY", "")
S3_BUCKET     = os.environ.get("BACKUP_S3_BUCKET", "")
S3_PREFIX     = os.environ.get("BACKUP_S3_PREFIX", PROFILE)
RETENTION_DAYS   = int(os.environ.get("BACKUP_RETENTION_DAYS", "0"))
CLEANUP_TARGET   = os.environ.get("BACKUP_CLEANUP_TARGET", "databases")

# FTP
FTP_HOST = os.environ.get("BACKUP_FTP_HOST", "")
FTP_PORT = int(os.environ.get("BACKUP_FTP_PORT", "21"))
FTP_USER = os.environ.get("BACKUP_FTP_USER", "")
FTP_PASS = os.environ.get("BACKUP_FTP_PASS", "")
FTP_DEST = os.environ.get("BACKUP_FTP_DEST", "/")
FTP_SSL  = os.environ.get("BACKUP_FTP_SSL", "off").lower()

_default_ftp_workers = 4
_default_s3_workers  = 10

# SFTP
SFTP_HOST = os.environ.get("BACKUP_SFTP_HOST", "")
SFTP_PORT = int(os.environ.get("BACKUP_SFTP_PORT", "22"))
SFTP_USER = os.environ.get("BACKUP_SFTP_USER", "")
SFTP_KEY  = os.environ.get("BACKUP_SFTP_KEY", "")
SFTP_PASS = os.environ.get("BACKUP_SFTP_PASS", "")
SFTP_DEST = os.environ.get("BACKUP_SFTP_DEST", "/")

_default_sftp_workers = 6

_default_workers = {
    "s3": _default_s3_workers,
    "ftp": _default_ftp_workers,
    "sftp": _default_sftp_workers,
}.get(TYPE, 10)

MAX_WORKERS = int(os.environ.get("BACKUP_MAX_WORKERS", str(_default_workers)))

# ── logging ───────────────────────────────────────────────────────────────────

_logger = logging.getLogger("backup-engine")
_logger.setLevel(logging.DEBUG)
_ch = logging.StreamHandler(sys.stdout)
_ch.setFormatter(logging.Formatter("%(message)s"))
_logger.addHandler(_ch)

if LOG_FILE_PATH:
    try:
        Path(LOG_FILE_PATH).parent.mkdir(parents=True, exist_ok=True)
        _fh = logging.FileHandler(LOG_FILE_PATH, encoding="utf-8")
        _fh.setFormatter(logging.Formatter(
            '{"time":"%(asctime)s","level":"%(levelname)s","msg":%(message)s}',
            datefmt="%Y-%m-%dT%H:%M:%S"
        ))
        _logger.addHandler(_fh)
    except OSError:
        pass

def _q(s): return json.dumps(str(s))

def log(msg):   _logger.info(_q(msg))
def logw(msg):  _logger.warning(_q(f"WARN: {msg}"))
def loge(msg):  _logger.error(_q(f"ERR: {msg}"))
def logd(msg):  _logger.debug(_q(f"dbg: {msg}"))

# ── shutdown flag ─────────────────────────────────────────────────────────────

_shutdown = threading.Event()
_progress_lock = threading.Lock()

def _sig(signum, frame):
    _shutdown.set()
    print("\n[!] Shutdown requested — finishing current transfers…", flush=True)

signal.signal(signal.SIGINT,  _sig)
signal.signal(signal.SIGTERM, _sig)

# ── SQLite state ──────────────────────────────────────────────────────────────

class StateDB:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._path = str(path)
        self._local = threading.local()
        self._lock  = threading.Lock()
        self._init()

    def _conn(self):
        if not getattr(self._local, "conn", None):
            c = sqlite3.connect(self._path, timeout=60, check_same_thread=False)
            c.execute("PRAGMA journal_mode=WAL")
            c.execute("PRAGMA synchronous=NORMAL")
            c.execute("PRAGMA cache_size=-131072")
            c.execute("PRAGMA temp_store=MEMORY")
            c.row_factory = sqlite3.Row
            self._local.conn = c
        return self._local.conn

    def _init(self):
        with self._lock:
            c = self._conn()
            c.execute("""
                CREATE TABLE IF NOT EXISTS files (
                    rel_path    TEXT PRIMARY KEY,
                    folder      TEXT,
                    file_hash   TEXT,
                    size        INTEGER,
                    status      TEXT DEFAULT 'pending',
                    remote_id   TEXT,
                    last_checked TEXT
                )
            """)
            c.execute("CREATE INDEX IF NOT EXISTS idx_status  ON files(status)")
            c.execute("CREATE INDEX IF NOT EXISTS idx_folder  ON files(folder, status)")
            c.commit()

    def upsert_batch(self, rows, force=False):
        now = datetime.now().isoformat()
        with self._lock:
            c = self._conn()
            if force:
                c.executemany("""
                    INSERT INTO files (rel_path,folder,file_hash,size,status,last_checked)
                    VALUES (?,?,?,?,'pending',?)
                    ON CONFLICT(rel_path) DO UPDATE SET
                        file_hash=excluded.file_hash, size=excluded.size,
                        status='pending', last_checked=excluded.last_checked
                """, [(r[0],r[1],r[2],r[3],now) for r in rows])
            else:
                c.executemany("""
                    INSERT INTO files (rel_path,folder,file_hash,size,status,last_checked)
                    VALUES (?,?,?,?,'pending',?)
                    ON CONFLICT(rel_path) DO UPDATE SET
                        file_hash=excluded.file_hash, size=excluded.size,
                        status=CASE WHEN files.file_hash!=excluded.file_hash
                                    THEN 'pending' ELSE files.status END,
                        last_checked=excluded.last_checked
                """, [(r[0],r[1],r[2],r[3],now) for r in rows])
            c.commit()

    def mark_done(self, pairs):  # [(rel_path, remote_id), …]
        now = datetime.now().isoformat()
        with self._lock:
            c = self._conn()
            c.executemany(
                "UPDATE files SET status='uploaded',remote_id=?,last_checked=? WHERE rel_path=?",
                [(rid, now, p) for p, rid in pairs]
            )
            c.commit()

    def pending(self):
        c = self._conn()
        return [dict(r) for r in c.execute(
            "SELECT rel_path,file_hash,size FROM files WHERE status='pending'"
        )]

    def all_uploaded(self):
        c = self._conn()
        return {r["rel_path"] for r in c.execute(
            "SELECT rel_path FROM files WHERE status='uploaded'"
        )}

    def stats(self):
        c = self._conn()
        total  = c.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        done   = c.execute("SELECT COUNT(*) FROM files WHERE status='uploaded'").fetchone()[0]
        sz_tot = c.execute("SELECT COALESCE(SUM(size),0) FROM files").fetchone()[0]
        sz_up  = c.execute("SELECT COALESCE(SUM(size),0) FROM files WHERE status='uploaded'").fetchone()[0]
        return {"total": total, "uploaded": done, "pending": total-done,
                "total_bytes": sz_tot, "uploaded_bytes": sz_up}

# ── progress tracker ──────────────────────────────────────────────────────────

class Progress:
    def __init__(self, total: int, total_bytes: int):
        self.total = total
        self.total_bytes = total_bytes
        self.done = 0
        self.errors = 0
        self.skipped = 0
        self.bytes_done = 0
        self.start = time.time()
        self._is_tty = sys.stdout.isatty()
        self._last_print = 0.0

    def update(self, status: str, size: int = 0):
        with _progress_lock:
            if status == "ok":
                self.done += 1
                self.bytes_done += size
            elif status == "error":
                self.errors += 1
            elif status == "skip":
                self.skipped += 1
            self._print()

    def _print(self):
        now = time.time()
        if now - self._last_print < 0.25 and self.done + self.errors < self.total:
            return
        self._last_print = now
        elapsed  = max(now - self.start, 0.001)
        finished = self.done + self.errors
        speed    = self.bytes_done / elapsed / 1048576
        rate     = finished / elapsed if finished else 0
        eta      = (self.total - finished) / rate if rate > 0 else 0
        pct      = finished / self.total * 100 if self.total else 0
        bar_w    = 28
        filled   = int(bar_w * finished / self.total) if self.total else 0
        bar      = "█" * filled + "░" * (bar_w - filled)
        line = (f"\r  [{bar}] {pct:5.1f}%  "
                f"{finished:,}/{self.total:,}  "
                f"{speed:6.2f} MB/s  "
                f"ETA {int(eta)}s  "
                f"✖{self.errors}")
        if self._is_tty:
            print(line, end="", flush=True)
        elif now - self._last_print > 10:
            print(line, flush=True)

    def finish(self):
        elapsed = time.time() - self.start
        print(flush=True)
        log(f"Done in {elapsed:.1f}s — {self.done:,} uploaded, "
            f"{self.skipped:,} skipped, {self.errors:,} errors  "
            f"({self.bytes_done/1048576:.1f} MB)")

# ── file scanner ──────────────────────────────────────────────────────────────

def scan_source(base: Path) -> list:
    """Walk source, return [(rel_path, folder, hash, size), …]."""
    results = []
    for root, dirs, files in os.walk(base):
        dirs.sort()
        folder = os.path.relpath(root, base) if root != str(base) else "root"
        for name in sorted(files):
            full = os.path.join(root, name)
            rel  = os.path.relpath(full, base).replace("\\", "/")
            try:
                st = os.stat(full)
                results.append((rel, folder, f"{st.st_mtime:.3f}-{st.st_size}", st.st_size))
            except OSError:
                continue
    return results

# ══════════════════════════════════════════════════════════════════════════════
# S3 BACKEND
# ══════════════════════════════════════════════════════════════════════════════

_s3_local = threading.local()

def _s3_client():
    if not getattr(_s3_local, "client", None):
        try:
            import boto3
            from botocore.config import Config
        except ImportError:
            sys.exit("[!] boto3 not found. Install: pip3 install boto3")
        cfg = Config(
            max_pool_connections=MAX_WORKERS + 10,
            retries={"max_attempts": 3, "mode": "adaptive"},
            connect_timeout=10,
            read_timeout=60,
        )
        s = boto3.session.Session()
        _s3_local.client = s.client(
            "s3",
            endpoint_url=S3_ENDPOINT,
            aws_access_key_id=S3_ACCESS_KEY,
            aws_secret_access_key=S3_SECRET_KEY,
            config=cfg,
        )
    return _s3_local.client


def _s3_upload_one(task: dict, dry_run: bool):
    if _shutdown.is_set():
        return "cancel", task["rel_path"], None
    rel   = task["rel_path"]
    full  = SOURCE / rel
    s3key = f"{S3_PREFIX}/{rel}"
    if not full.exists():
        return "error", rel, None
    if dry_run:
        return "dry", rel, None
    s3 = _s3_client()
    ct, _ = mimetypes.guess_type(rel)
    extra = {"ACL": "private"}
    if ct:
        extra["ContentType"] = ct
    for attempt in range(3):
        if _shutdown.is_set():
            return "cancel", rel, None
        try:
            s3.upload_file(str(full), S3_BUCKET, s3key, ExtraArgs=extra)
            return "ok", rel, s3key
        except Exception as e:
            if attempt == 2:
                loge(f"s3 upload failed [{rel}]: {e}")
                return "error", rel, None
            time.sleep(0.5 * (attempt + 1))


def _s3_delete_missing(local_rels: set, dry_run: bool):
    """Delete S3 objects under PREFIX that are not in local_rels."""
    s3 = _s3_client()
    paginator = s3.get_paginator("list_objects_v2")
    to_delete = []
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=S3_PREFIX + "/"):
        for obj in page.get("Contents", []):
            rel = obj["Key"][len(S3_PREFIX) + 1:]
            if rel and rel not in local_rels:
                to_delete.append({"Key": obj["Key"]})
    if not to_delete:
        log("sync-delete: nothing to remove")
        return
    log(f"sync-delete: removing {len(to_delete):,} remote objects")
    if not dry_run:
        for i in range(0, len(to_delete), 1000):
            s3.delete_objects(Bucket=S3_BUCKET,
                              Delete={"Objects": to_delete[i:i+1000]})


def _s3_cleanup_old(dry_run: bool):
    if RETENTION_DAYS <= 0:
        return
    s3        = _s3_client()
    cutoff    = datetime.now() - timedelta(days=RETENTION_DAYS)
    prefix    = f"{S3_PREFIX}/{CLEANUP_TARGET}/"
    date_re   = re.compile(r"/(\d{4}-\d{2}-\d{2})/")
    paginator = s3.get_paginator("list_objects_v2")
    deleted   = 0
    log(f"retention: checking {prefix} (>{RETENTION_DAYS}d old)…")
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            m = date_re.search(obj["Key"])
            if not m:
                continue
            try:
                d = datetime.strptime(m.group(1), "%Y-%m-%d")
                if d < cutoff:
                    if not dry_run:
                        s3.delete_object(Bucket=S3_BUCKET, Key=obj["Key"])
                    deleted += 1
            except ValueError:
                continue
    log(f"retention: removed {deleted:,} old objects")


def run_s3(db: StateDB, pending: list, dry_run: bool, local_rels: set):
    prog = Progress(len(pending), sum(t["size"] for t in pending))
    log(f"[S3] uploading {len(pending):,} files → s3://{S3_BUCKET}/{S3_PREFIX}")
    done_pairs = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        tasks = [{"rel_path": t["rel_path"], "size": t["size"]} for t in pending]
        futs  = {ex.submit(_s3_upload_one, t, dry_run): t for t in tasks}
        for fut in as_completed(futs):
            if _shutdown.is_set():
                ex.shutdown(wait=False, cancel_futures=True)
                break
            status, rel, rid = fut.result()
            t = futs[fut]
            if status == "ok":
                done_pairs.append((rel, rid or ""))
                prog.update("ok", t["size"])
            elif status == "dry":
                prog.update("skip", t["size"])
            else:
                prog.update("error")
    if done_pairs and not dry_run:
        db.mark_done(done_pairs)
    prog.finish()
    if DELETE:
        _s3_delete_missing(local_rels, dry_run)
    _s3_cleanup_old(dry_run)

# ══════════════════════════════════════════════════════════════════════════════
# FTP BACKEND
# ══════════════════════════════════════════════════════════════════════════════

_ftp_local = threading.local()

def _ftp_connect():
    if FTP_SSL in ("explicit",):
        ftp = ftplib.FTP_TLS()
        ftp.connect(FTP_HOST, FTP_PORT, timeout=30)
        ftp.auth()
        ftp.login(FTP_USER, FTP_PASS)
        ftp.prot_p()
    elif FTP_SSL == "implicit":
        import ssl
        ctx = ssl.create_default_context()
        ftp = ftplib.FTP_TLS(context=ctx)
        ftp.connect(FTP_HOST, FTP_PORT, timeout=30)
        ftp.login(FTP_USER, FTP_PASS)
        ftp.prot_p()
    else:
        ftp = ftplib.FTP()
        ftp.connect(FTP_HOST, FTP_PORT, timeout=30)
        ftp.login(FTP_USER, FTP_PASS)
    ftp.set_pasv(True)
    return ftp

def _ftp_client():
    if not getattr(_ftp_local, "ftp", None):
        _ftp_local.ftp = _ftp_connect()
    try:
        _ftp_local.ftp.voidcmd("NOOP")
    except Exception:
        _ftp_local.ftp = _ftp_connect()
    return _ftp_local.ftp

def _ftp_makedirs(ftp, remote_path: str):
    parts = remote_path.replace("\\", "/").strip("/").split("/")
    current = ""
    for part in parts:
        current = ("/" + current + "/" + part).replace("//", "/")
        try:
            ftp.cwd(current)
        except ftplib.error_perm:
            try:
                ftp.mkd(current)
            except ftplib.error_perm:
                pass

def _ftp_list_recursive(ftp, path: str) -> set:
    result = set()
    try:
        entries = list(ftp.mlsd(path, facts=["type"]))
        for name, facts in entries:
            if name in (".", ".."):
                continue
            full = f"{path.rstrip('/')}/{name}"
            if facts.get("type") == "file":
                result.add(full)
            elif facts.get("type") == "dir":
                result.update(_ftp_list_recursive(ftp, full))
    except Exception:
        try:
            items = ftp.nlst(path)
            for item in items:
                if item.strip("/").split("/")[-1] not in (".", ".."):
                    result.add(item)
        except Exception:
            pass
    return result

def _ftp_upload_one(task: dict, dry_run: bool):
    if _shutdown.is_set():
        return "cancel", task["rel_path"], None
    rel      = task["rel_path"]
    full     = SOURCE / rel
    remote   = (FTP_DEST.rstrip("/") + "/" + rel).replace("\\", "/")
    remote_d = remote.rsplit("/", 1)[0]
    if not full.exists():
        return "error", rel, None
    if dry_run:
        return "dry", rel, None
    ftp = _ftp_client()
    for attempt in range(3):
        if _shutdown.is_set():
            return "cancel", rel, None
        try:
            _ftp_makedirs(ftp, remote_d)
            with open(full, "rb") as f:
                ftp.storbinary(f"STOR {remote}", f, blocksize=65536)
            return "ok", rel, remote
        except Exception as e:
            if attempt == 2:
                loge(f"ftp upload failed [{rel}]: {e}")
                return "error", rel, None
            try:
                _ftp_local.ftp = _ftp_connect()
                ftp = _ftp_local.ftp
            except Exception:
                return "error", rel, None

def _ftp_delete_missing(local_rels: set, dry_run: bool):
    ftp = _ftp_connect()  # fresh conn for listing
    remote_files = _ftp_list_recursive(ftp, FTP_DEST)
    dest_base = FTP_DEST.rstrip("/")
    to_delete = []
    for rf in remote_files:
        rel = rf[len(dest_base):].lstrip("/") if rf.startswith(dest_base) else rf
        if rel and rel not in local_rels:
            to_delete.append(rf)
    if not to_delete:
        log("sync-delete: nothing to remove")
        return
    log(f"sync-delete: removing {len(to_delete):,} remote files")
    if not dry_run:
        for rf in to_delete:
            try:
                ftp.delete(rf)
            except Exception as e:
                logw(f"ftp delete failed [{rf}]: {e}")
    ftp.quit()

def run_ftp(db: StateDB, pending: list, dry_run: bool, local_rels: set):
    prog = Progress(len(pending), sum(t["size"] for t in pending))
    log(f"[FTP] uploading {len(pending):,} files → {FTP_HOST}:{FTP_PORT}{FTP_DEST}")
    done_pairs = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        tasks = [{"rel_path": t["rel_path"], "size": t["size"]} for t in pending]
        futs  = {ex.submit(_ftp_upload_one, t, dry_run): t for t in tasks}
        for fut in as_completed(futs):
            if _shutdown.is_set():
                ex.shutdown(wait=False, cancel_futures=True)
                break
            status, rel, rid = fut.result()
            t = futs[fut]
            if status == "ok":
                done_pairs.append((rel, rid or ""))
                prog.update("ok", t["size"])
            elif status == "dry":
                prog.update("skip", t["size"])
            else:
                prog.update("error")
    if done_pairs and not dry_run:
        db.mark_done(done_pairs)
    prog.finish()
    if DELETE:
        _ftp_delete_missing(local_rels, dry_run)

# ══════════════════════════════════════════════════════════════════════════════
# SFTP BACKEND
# ══════════════════════════════════════════════════════════════════════════════

_sftp_local = threading.local()

def _sftp_connect():
    try:
        import paramiko
    except ImportError:
        sys.exit("[!] paramiko not found. Install: pip3 install paramiko")
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kwargs: dict = {"hostname": SFTP_HOST, "port": SFTP_PORT, "username": SFTP_USER,
                    "timeout": 30, "banner_timeout": 30}
    if SFTP_KEY:
        kwargs["key_filename"] = SFTP_KEY
    elif SFTP_PASS:
        kwargs["password"] = SFTP_PASS
    ssh.connect(**kwargs)
    sftp = ssh.open_sftp()
    return ssh, sftp

def _sftp_client():
    if not getattr(_sftp_local, "sftp", None):
        _sftp_local.ssh, _sftp_local.sftp = _sftp_connect()
    try:
        _sftp_local.sftp.stat(".")
    except Exception:
        try:
            _sftp_local.ssh.close()
        except Exception:
            pass
        _sftp_local.ssh, _sftp_local.sftp = _sftp_connect()
    return _sftp_local.sftp

def _sftp_makedirs(sftp, path: str):
    parts = path.replace("\\", "/").strip("/").split("/")
    current = "" if not path.startswith("/") else "/"
    for part in parts:
        current = (current.rstrip("/") + "/" + part).lstrip("/")
        if path.startswith("/"):
            current = "/" + current.lstrip("/")
        try:
            sftp.stat(current)
        except IOError:
            try:
                sftp.mkdir(current)
            except IOError:
                pass

def _sftp_list_recursive(sftp, path: str) -> set:
    result = set()
    try:
        entries = sftp.listdir_attr(path)
        import stat as _stat
        for entry in entries:
            full = f"{path.rstrip('/')}/{entry.filename}"
            if _stat.S_ISDIR(entry.st_mode or 0):
                result.update(_sftp_list_recursive(sftp, full))
            else:
                result.add(full)
    except Exception:
        pass
    return result

def _sftp_upload_one(task: dict, dry_run: bool):
    if _shutdown.is_set():
        return "cancel", task["rel_path"], None
    rel      = task["rel_path"]
    full     = SOURCE / rel
    remote   = (SFTP_DEST.rstrip("/") + "/" + rel).replace("\\", "/")
    remote_d = remote.rsplit("/", 1)[0]
    if not full.exists():
        return "error", rel, None
    if dry_run:
        return "dry", rel, None
    sftp = _sftp_client()
    for attempt in range(3):
        if _shutdown.is_set():
            return "cancel", rel, None
        try:
            _sftp_makedirs(sftp, remote_d)
            sftp.put(str(full), remote)
            return "ok", rel, remote
        except Exception as e:
            if attempt == 2:
                loge(f"sftp upload failed [{rel}]: {e}")
                return "error", rel, None
            try:
                _sftp_local.ssh.close()
            except Exception:
                pass
            try:
                _sftp_local.ssh, _sftp_local.sftp = _sftp_connect()
                sftp = _sftp_local.sftp
            except Exception:
                return "error", rel, None

def _sftp_delete_missing(local_rels: set, dry_run: bool):
    _, sftp = _sftp_connect()
    remote_files = _sftp_list_recursive(sftp, SFTP_DEST)
    dest_base = SFTP_DEST.rstrip("/")
    to_delete = []
    for rf in remote_files:
        rel = rf[len(dest_base):].lstrip("/") if rf.startswith(dest_base) else rf
        if rel and rel not in local_rels:
            to_delete.append(rf)
    if not to_delete:
        log("sync-delete: nothing to remove")
        return
    log(f"sync-delete: removing {len(to_delete):,} remote files")
    if not dry_run:
        for rf in to_delete:
            try:
                sftp.remove(rf)
            except Exception as e:
                logw(f"sftp delete failed [{rf}]: {e}")
    sftp.close()

def run_sftp(db: StateDB, pending: list, dry_run: bool, local_rels: set):
    prog = Progress(len(pending), sum(t["size"] for t in pending))
    log(f"[SFTP] uploading {len(pending):,} files → {SFTP_USER}@{SFTP_HOST}:{SFTP_PORT}{SFTP_DEST}")
    done_pairs = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        tasks = [{"rel_path": t["rel_path"], "size": t["size"]} for t in pending]
        futs  = {ex.submit(_sftp_upload_one, t, dry_run): t for t in tasks}
        for fut in as_completed(futs):
            if _shutdown.is_set():
                ex.shutdown(wait=False, cancel_futures=True)
                break
            status, rel, rid = fut.result()
            t = futs[fut]
            if status == "ok":
                done_pairs.append((rel, rid or ""))
                prog.update("ok", t["size"])
            elif status == "dry":
                prog.update("skip", t["size"])
            else:
                prog.update("error")
    if done_pairs and not dry_run:
        db.mark_done(done_pairs)
    prog.finish()
    if DELETE:
        _sftp_delete_missing(local_rels, dry_run)

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def _validate():
    errors = []
    if not SOURCE or not SOURCE.is_dir():
        errors.append(f"BACKUP_SOURCE not set or not a directory: '{SOURCE}'")
    if TYPE == "s3":
        for v, k in [(S3_ENDPOINT,"S3_ENDPOINT"),(S3_ACCESS_KEY,"S3_ACCESS_KEY"),
                     (S3_SECRET_KEY,"S3_SECRET_KEY"),(S3_BUCKET,"S3_BUCKET"),(S3_PREFIX,"S3_PREFIX")]:
            if not v: errors.append(f"BACKUP_{k} not set")
    elif TYPE == "ftp":
        for v, k in [(FTP_HOST,"FTP_HOST"),(FTP_USER,"FTP_USER"),(FTP_PASS,"FTP_PASS"),(FTP_DEST,"FTP_DEST")]:
            if not v: errors.append(f"BACKUP_{k} not set")
    elif TYPE == "sftp":
        for v, k in [(SFTP_HOST,"SFTP_HOST"),(SFTP_USER,"SFTP_USER"),(SFTP_DEST,"SFTP_DEST")]:
            if not v: errors.append(f"BACKUP_{k} not set")
        if not SFTP_KEY and not SFTP_PASS:
            errors.append("BACKUP_SFTP_KEY or BACKUP_SFTP_PASS required")
    else:
        errors.append(f"Unknown BACKUP_TYPE: '{TYPE}'. Use: s3 | ftp | sftp")
    return errors


def main():
    ap = argparse.ArgumentParser(description="backup-engine — S3/FTP/SFTP backup")
    ap.add_argument("--dry-run",   action="store_true")
    ap.add_argument("--force",     action="store_true", help="re-upload all files")
    ap.add_argument("--skip-scan", action="store_true", help="skip scan, retry pending only")
    ap.add_argument("--status",    action="store_true", help="show DB stats and exit")
    args = ap.parse_args()

    errors = _validate()
    if errors:
        for e in errors:
            loge(e)
        sys.exit(1)

    db = StateDB(DB_PATH)

    if args.status:
        s = db.stats()
        print(f"  Profile : {PROFILE}")
        print(f"  Type    : {TYPE}")
        print(f"  Source  : {SOURCE}")
        print(f"  Total   : {s['total']:,} files  ({s['total_bytes']/1048576:.1f} MB)")
        pct = s['uploaded']/s['total']*100 if s['total'] else 0
        bar = "█" * int(28*pct/100) + "░" * (28 - int(28*pct/100))
        print(f"  [{bar}] {pct:.1f}%")
        print(f"  Done    : {s['uploaded']:,}  Pending: {s['pending']:,}")
        return

    start_ts = datetime.now().isoformat()
    log(f"=== backup-engine start === profile={PROFILE} type={TYPE} "
        f"dry={args.dry_run} force={args.force} workers={MAX_WORKERS}")

    # Scan
    local_rels: set = set()
    if not args.skip_scan:
        log(f"scanning {SOURCE} …")
        scanned = scan_source(SOURCE)
        local_rels = {r[0] for r in scanned}
        log(f"found {len(scanned):,} files")
        if scanned:
            db.upsert_batch(scanned, force=args.force)
    else:
        log("skipping scan (--skip-scan)")

    pending = db.pending()
    if not pending:
        log("nothing to upload — all files up to date")
        s = db.stats()
        log(f"state: {s['uploaded']:,}/{s['total']:,} files uploaded")
        return

    log(f"pending: {len(pending):,} files")

    # Run backend
    if TYPE == "s3":
        run_s3(db, pending, args.dry_run, local_rels)
    elif TYPE == "ftp":
        run_ftp(db, pending, args.dry_run, local_rels)
    elif TYPE == "sftp":
        run_sftp(db, pending, args.dry_run, local_rels)

    s = db.stats()
    log(f"=== done === {s['uploaded']:,}/{s['total']:,} total uploaded "
        f"({s['uploaded_bytes']/1048576:.1f} MB)")


if __name__ == "__main__":
    main()
