"""Per-slot attempt custody, content transport, and result replay."""
import fcntl
import hashlib
import http.client
import json
import os
from pathlib import Path
import queue
import re
import sqlite3
import struct
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit

from worker_executor import limits_from_environment, MAX_BLOB, EngineUnavailable, Rejected, cleanup, digest, execute


class Offline(Exception):
    """No configured controller acknowledged this request."""


class CorePort:
    """Single outstanding codec request. Closing the VM pipe releases the slot."""
    def __init__(self):
        self.replies = queue.Queue()
        threading.Thread(target=self.read_replies, daemon=True).start()

    @staticmethod
    def read_exact(size):
        out = bytearray()
        while len(out) < size:
            chunk = os.read(0, size - len(out))
            if not chunk:
                os._exit(1)
            out.extend(chunk)
        return bytes(out)

    def read_replies(self):
        while True:
            size, = struct.unpack(">I", self.read_exact(4))
            self.replies.put(self.read_exact(size))

    def check(self, kind, payload):
        packet = kind + payload
        sys.stdout.buffer.write(struct.pack(">I", len(packet)) + packet)
        sys.stdout.buffer.flush()
        reply = self.replies.get()
        if reply[:1] != b"\x01":
            raise ValueError("invalid " + ("assignment" if kind == b"A" else "completion"))
        return json.loads(reply[1:])


class Controllers:
    def __init__(self, endpoints, token):
        self.endpoints = [urlsplit(e.strip()) for e in endpoints.split(",")]
        for e in self.endpoints:
            if (e.scheme not in ("http", "https") or not e.hostname or e.username
                    or e.password or e.path not in ("", "/") or e.query or e.fragment):
                raise ValueError("GANTRY_ENDPOINT must contain HTTP(S) origins")
        self.headers = {"Authorization": "Bearer " + token}
        self.next = 0

    def request(self, method, path, data=None, content_type="application/json"):
        for idx in range(len(self.endpoints)):
            index = (self.next + idx) % len(self.endpoints)
            url = self.endpoints[index]
            connection = (http.client.HTTPSConnection if url.scheme == "https"
                          else http.client.HTTPConnection)(url.hostname, url.port, timeout=20)
            try:
                connection.request(method, path, body=data,
                                   headers={**self.headers, "Content-Type": content_type})
                response = connection.getresponse()
                body = response.read(MAX_BLOB + 1)
                if len(body) > MAX_BLOB:
                    raise Rejected("controller response exceeded size limit")
                if response.status < 500:
                    self.next = index
                    return response.status, body
            except (OSError, http.client.HTTPException):
                pass
            finally:
                connection.close()
        raise Offline("no controller available")

    def fetch(self, sha):
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise Rejected("invalid input digest")
        status, data = self.request("GET", "/v1/blobs/" + sha)
        if status != 200:
            raise Offline("input blob unavailable")
        if digest(data) != sha:
            raise Rejected("input failed SHA-256 verification")
        return data


class Slot:
    def __init__(self, directory, worker, pool, network, check):
        self.check = check
        self.limits = limits_from_environment()
        self.directory, self.worker, self.pool, self.network = directory, worker, pool, network
        self.db = sqlite3.connect(directory / "custody.sqlite3")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("CREATE TABLE IF NOT EXISTS identity(worker TEXT PRIMARY KEY)")
        existing = self.db.execute("SELECT worker FROM identity").fetchone()
        if existing and existing[0] != worker:
            raise ValueError("GANTRY_WORKER_DIR already belongs to a different worker ID")
        self.db.execute("INSERT OR IGNORE INTO identity VALUES (?)", (worker,))
        self.db.execute("""CREATE TABLE IF NOT EXISTS attempts(
            name TEXT PRIMARY KEY, assignment TEXT NOT NULL, receipt TEXT, acknowledged INTEGER DEFAULT 0, started INTEGER DEFAULT 0)""")
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(attempts)")}
        if "started" not in columns:
            self.db.execute("ALTER TABLE attempts ADD COLUMN started INTEGER DEFAULT 1")
        self.db.execute("CREATE TABLE IF NOT EXISTS blobs(sha TEXT PRIMARY KEY, data BLOB NOT NULL)")
        self.db.commit()

    def spool(self, data):
        sha = digest(data)
        self.db.execute("INSERT OR IGNORE INTO blobs VALUES (?,?)", (sha, data))
        return sha

    def record(self, name, assignment, completion):
        envelope = {"worker": self.worker, "run": assignment["run"],
                    "serial": assignment["lease"]["serial"], "action": assignment["task"]["action"]["name"],
                    "completion": self.check(b"C", json.dumps(completion).encode())}
        self.db.execute("UPDATE attempts SET receipt=? WHERE name=?", (json.dumps(envelope), name))
        self.db.commit()

    def rejected(self, reason):
        return {"kind": "rejected", "reason": reason, "log": self.spool(reason.encode())}

    def publish(self, name, receipt):
        for sha, data in self.db.execute("SELECT sha,data FROM blobs"):
            status, _ = self.network.request("PUT", "/v1/blobs/" + sha, data, "application/octet-stream")
            if status != 200:
                raise Offline(f"blob upload returned {status}")
        status, _ = self.network.request("POST", "/v1/results", receipt.encode())
        if status not in (200, 409):
            raise Offline(f"completion returned {status}")
        with self.db:
            self.db.execute("UPDATE attempts SET acknowledged=1 WHERE name=?", (name,))
            self.db.execute("DELETE FROM blobs")

    def step(self):
        pending = self.db.execute(
            "SELECT name,assignment,receipt,started FROM attempts WHERE acknowledged=0 LIMIT 1").fetchone()
        if pending:
            name, payload, receipt, started = pending
            if receipt is not None:
                self.publish(name, receipt)
            elif started:
                cleanup(name)
                self.record(name, json.loads(payload), self.rejected("worker interrupted before recording outcome"))
            else:
                self.perform(name, json.loads(payload))
            return True
        claim = json.dumps({"worker": self.worker, "pool": self.pool}).encode()
        status, payload = self.network.request("POST", "/v1/claims", claim)
        if status == 204:
            return False
        if status != 200:
            raise Offline(f"claim returned {status}")
        assignment = self.check(b"A", payload)
        lease, task = assignment["lease"], assignment["task"]
        if lease["worker"] != self.worker or task["pool"] != self.pool:
            raise ValueError("assignment does not match this worker and pool")
        key = json.dumps([str(self.directory.resolve()), self.worker, assignment["run"], task["action"]["name"], lease["serial"]]).encode()
        name = "gantry-" + hashlib.sha256(key).hexdigest()
        with self.db:
            old = self.db.execute("SELECT receipt FROM attempts WHERE name=?", (name,)).fetchone()
            if old is not None:
                self.db.execute("UPDATE attempts SET acknowledged=0 WHERE name=?", (name,))
                return True
            self.db.execute("INSERT INTO attempts(name,assignment,started) VALUES (?,?,0)",
                            (name, json.dumps(assignment)))
        return True

    def perform(self, name, assignment):
        def mark_started():
            with self.db:
                self.db.execute("UPDATE attempts SET started=1 WHERE name=?", (name,))

        try:
            with tempfile.TemporaryDirectory(dir=self.directory) as tmp:
                try:
                    result = execute(Path(tmp), name, assignment, self.network.fetch, self.spool, mark_started, self.limits)
                except (Rejected, ValueError, OSError, KeyError, TypeError) as e:
                    result = self.rejected(str(e)[:1024])
        finally:
            cleanup(name)
        self.record(name, assignment, result)


def main():
    port = CorePort()
    os.umask(0o077)
    directory = Path(os.environ["GANTRY_WORKER_DIR"])
    if not directory.is_absolute() or any(c in str(directory) for c in ",\n\r"):
        raise ValueError("GANTRY_WORKER_DIR must be an absolute Docker mount path")
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "slot.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        worker, pool = os.environ["GANTRY_WORKER_ID"], os.environ["GANTRY_POOL"]
        if not worker or not pool or not os.environ["GANTRY_WORKER_TOKEN"]:
            raise ValueError("worker ID, pool and token must be nonempty")
        network = Controllers(os.environ["GANTRY_ENDPOINT"], os.environ["GANTRY_WORKER_TOKEN"])
        slot = Slot(directory, worker, pool, network, port.check)
        while True:
            try:
                if slot.step():
                    continue
            except (Offline, EngineUnavailable) as e:
                print("gantry worker:", e, file=sys.stderr, flush=True)
            time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError) as e:
        sys.exit(f"gantry worker: {e}")
