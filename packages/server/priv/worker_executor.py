"""Docker boundary. Only the verified source and dependency archives enter the action."""

import hashlib
import io
import os
from pathlib import Path
import re
import selectors
import subprocess
import tarfile
import time

MAX_BLOB = 64 * 1024 * 1024
MAX_LOG = 64 * 1024
COLLECTOR_IMAGE = "alpine@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"
SAFE = re.compile(r"[a-zA-Z0-9_.-]+")
RESTRICT = ["--pull=never", "--network=none", "--cap-drop=ALL", "--read-only",
            "--user=65534:65534", "--security-opt=no-new-privileges", "--pids-limit=128",
            "--log-driver=none", "--ulimit=nofile=1024:1024"]


class Rejected(Exception):
    """A terminal action failure whose log can be published."""


class EngineUnavailable(Exception):
    """The worker must retain custody until the engine acknowledges cleanup."""


def safe_path(value):
    return (isinstance(value, str) and len(value) <= 240
            and all(SAFE.fullmatch(p) and p not in (".", "..", ".git")
                    for p in value.split("/")))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def engine_env():
    # Never forward the controller token, Git credentials, or Docker client config.
    return {"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
            "DOCKER_CONFIG": "/nonexistent",
            **{k: os.environ[k] for k in ("DOCKER_HOST", "XDG_RUNTIME_DIR") if k in os.environ}}


def control(args, missing=None):
    try:
        r = subprocess.run(["docker", *args], env=engine_env(), capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise EngineUnavailable("Docker control request failed") from e
    if r.returncode and not (missing and missing in r.stderr.lower()):
        raise EngineUnavailable(r.stderr[:512].decode(errors="replace"))
    return r.stdout


def cleanup(name):
    # Explicit names are persisted before any create request, including unknown outcomes.
    for container in (name, name + "-collector"):
        control(["rm", "-fv", container], missing=b"no such container")
    control(["volume", "rm", name], missing=b"no such volume")


def stage(directory, assignment, fetch):
    action = assignment["task"]["action"]
    source = directory / "source.tar"
    source.write_bytes(fetch(assignment["task"]["source"]))
    source.chmod(0o644)
    # Tar is unpacked only inside the isolated container. Reject source links
    # along dependency destinations so staging preserves the declared logical paths.
    blocked = set()
    try:
        with tarfile.open(source, "r:") as tree:
            for member in tree:
                parts = member.name.rstrip("/").split("/")
                if member.name.startswith("/") or any(p in ("", ".", "..") for p in parts):
                    raise Rejected("unsafe path in source archive")
                if not member.isdir():
                    blocked.add(member.name)
                if not (member.isdir() or member.isfile() or member.issym()):
                    raise Rejected("unsupported entry in source archive")
    except tarfile.TarError as e:
        raise Rejected("invalid Git source archive") from e

    dependencies = directory / "dependencies.tar"
    with tarfile.open(dependencies, "w") as archive:
        for item in assignment["lease"]["key"]["dependencies"]:
            path = item["path"]
            if not safe_path(path):
                raise Rejected("invalid dependency path")
            if any(str(p) in blocked for p in Path(path).parents):
                raise Rejected("dependency crosses a non-directory source entry")
            data = fetch(item["digest"])
            entry = tarfile.TarInfo(path)
            entry.size = len(data)
            entry.mode = 0o644
            archive.addfile(entry, io.BytesIO(data))
            if archive.offset > MAX_BLOB:
                raise Rejected("dependency archive exceeds worker size limit")
    dependencies.chmod(0o644)
    if not all(safe_path(p) for p in action["outputs"]):
        raise Rejected("invalid output path")
    return source, dependencies


def run_logged(args, timeout):
    """Drain both streams even after the retained log reaches its byte budget."""
    with subprocess.Popen(["docker", *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, env=engine_env()) as process:
        deadline = time.monotonic() + timeout
        log = bytearray()
        truncated = False
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise Rejected("action exceeded its wall deadline")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    size = min(MAX_LOG - len(log), len(chunk))
                    log.extend(chunk[:size])
                    truncated |= size < len(chunk)
            status = process.wait(timeout=max(0, deadline - time.monotonic()))
        finally:
            process.kill()
        if truncated:
            log.extend(b"\n[output truncated]\n")
        return status, bytes(log)


def outputs(name, paths, spool):
    # The action and its children have exited. The collector alone mounts
    # the volume, read-only. Check every component before opening a file;
    # unrelated files, including arbitrarily large sparse files, are never read.
    reader = """
        set -efu
        path=$1
        set -f
        IFS=/
        current=/work
        for part in $path; do
            current=$current/$part
            [ ! -L "$current" ] || exit 1
        done
        [ -f "$current" ] || exit 1
        size=$(stat -c %s "$current") || exit 1
        [ "$size" -le "$2" ] || exit 1
        exec cat "$current"
    """
    files = []
    for path in paths:
        cmd = ["docker", "exec", name + "-collector", "/bin/sh", "-c",
               reader, "gantry-collector", path, str(MAX_BLOB)]
        result = subprocess.run(cmd, capture_output=True, env=engine_env(), timeout=60)
        if result.returncode:
            raise Rejected("missing, linked, unreadable or oversized declared output: " + path)
        files.append({"path": path, "digest": spool(result.stdout)})
    return files


def resource_limit(key, default, minimum, maximum):
    value = int(os.environ.get(key, default))
    if not minimum <= value <= maximum:
        raise ValueError(f"{key} must be between {minimum} and {maximum}")
    return value


def limits_from_environment():
    return (
        resource_limit("GANTRY_WORKER_CPUS", 2, 1, 1024),
        resource_limit("GANTRY_WORKER_MEMORY_MIB", 768, 128, 2_097_152),
        resource_limit("GANTRY_WORKSPACE_MIB", 256, 64, 1_048_576),
    )


def execute(directory, name, assignment, fetch, spool, mark_started, limits):
    action, image = assignment["task"]["action"], assignment["task"]["image"]
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_./:@-]*", image):
        raise Rejected("invalid image reference")
    argv = action["argv"]
    if not argv or not all(isinstance(arg, str) and "\0" not in arg for arg in argv):
        raise Rejected("invalid action argv")
    timeout = action["timeout"]
    if type(timeout) is not int or not 0 < timeout <= 3600:
        raise Rejected("invalid action deadline")
    cpus, memory, workspace = limits
    source, deps = stage(directory, assignment, fetch)
    mark_started()
    control(["volume", "create", "--driver", "local", "--opt", "type=tmpfs",
             "--opt", "device=tmpfs", "--opt", f"o=size={workspace}m,nr_inodes=1048576,mode=1777", name])
    mount = "type=volume,src=" + name + ",dst=/work,volume-nocopy"
    control(["run", "-d", *RESTRICT, "--name", name + "-collector", "--mount", mount + ",readonly",
             "--memory=128m", "--cpus=0.25", "--entrypoint", "/bin/sleep", COLLECTOR_IMAGE, "7200"])
    unpack = 'set -eu; tar xf /source.tar; tar xf /dependencies.tar; exec "$@"'
    args = ["create", *RESTRICT, f"--memory={memory}m", f"--cpus={cpus}",
            "--name", name, "--mount", mount, "--workdir", "/work",
            "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m,mode=1777",
            "--mount", f"type=bind,src={source},dst=/source.tar,readonly",
            "--mount", f"type=bind,src={deps},dst=/dependencies.tar,readonly",
            "--entrypoint", "/bin/sh", image, "-c", unpack, "gantry", *argv]
    # A delayed create can only leave a stopped container. A delayed start
    # names the original immutable ID and cannot restart a replacement.
    identity = control(args).decode().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", identity):
        raise EngineUnavailable("Docker returned an invalid container ID")
    status, log = run_logged(["start", "-a", identity], timeout)
    state = control(["inspect", "--format", "{{.State.Status}} {{.State.ExitCode}}", identity])
    if not state.startswith(b"exited "):
        raise Rejected("container failed to exit normally")
    status = int(state.split()[1]) or status
    log_id = spool(log)
    control(["rm", "-fv", name], missing=b"no such container")
    if status:
        return {"kind": "rejected", "reason": f"action exited with status {status}", "log": log_id}
    try:
        files = outputs(name, action["outputs"], spool)
    except (Rejected, subprocess.TimeoutExpired) as error:
        return {"kind": "rejected", "reason": str(error)[:1024], "log": log_id}
    return {"kind": "succeeded", "files": files, "log": log_id}
