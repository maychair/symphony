"""Host-owned Linux check supervisor. Commands never write the journal receipt."""
import ctypes
import hashlib
import json
import os
import pathlib
import selectors
import signal
import subprocess
import sys
import time


def isolate(workspace, temporary, git_directory, read_roots):
    """Deny command access to host journals, credentials and writable Git metadata."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.syscall(444, 0, 0, 1) < 3:
        raise OSError("Linux Landlock ABI 3 or newer is required")

    class Ruleset(ctypes.Structure):
        _fields_ = [("handled", ctypes.c_uint64)]

    class PathRule(ctypes.Structure):
        _pack_ = 1
        _fields_ = [("access", ctypes.c_uint64), ("parent", ctypes.c_int)]

    handled = (1 << 15) - 1
    ruleset = Ruleset(handled)
    descriptor = libc.syscall(444, ctypes.byref(ruleset), ctypes.sizeof(ruleset), 0)
    if descriptor < 0:
        raise OSError(ctypes.get_errno(), "cannot create check filesystem isolation")
    read = (1 << 0) | (1 << 2) | (1 << 3)
    try:
        paths = {str(pathlib.Path(value).resolve()): access for value, access in [
            ("/usr", read), ("/bin", read), ("/lib", read), ("/lib64", read),
            ("/etc", read), (git_directory, read),
            (workspace, handled), (temporary, handled),
            ("/dev/null", (1 << 1) | (1 << 2)), ("/dev/urandom", 1 << 2),
        ] + [(value, read) for value in read_roots] if pathlib.Path(value).exists()}
        for path, access in paths.items():
            parent = os.open(path, os.O_PATH | os.O_CLOEXEC)
            try:
                rule = PathRule(access, parent)
                if libc.syscall(445, descriptor, 1, ctypes.byref(rule), 0) != 0:
                    raise OSError(ctypes.get_errno(), "cannot add check filesystem rule")
            finally:
                os.close(parent)
        if libc.prctl(38, 1, 0, 0, 0) != 0 or libc.syscall(446, descriptor, 0) != 0:
            raise OSError(ctypes.get_errno(), "cannot activate check filesystem isolation")
    finally:
        os.close(descriptor)


def atomic_json(path, value):
    temporary = path.with_suffix(".pending")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def children():
    path = pathlib.Path(f"/proc/self/task/{os.getpid()}/children")
    return [int(value) for value in path.read_text().split()]


def stop_children():
    # A subreaper adopts descendants whose parents exit, including a command
    # that daemonizes into a new session. Reap them before claiming a stop.
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        pending = children()
        if not pending:
            return True
        for pid in pending:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        while True:
            try:
                waited, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if waited == 0:
                break
        time.sleep(0.01)
    return not children()


def snapshot(spec, initial=False):
    base = ["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", spec["workspace"]]
    environment = {"PATH": "/usr/bin:/bin"}
    try:
        head = subprocess.run(base + ["rev-parse", "HEAD"], capture_output=True, env=environment, timeout=5)
        clean = subprocess.run(
            base + ["diff", "--quiet", "--no-ext-diff", "--ignore-submodules=none", "HEAD", "--"],
            capture_output=True, env=environment, timeout=5,
        )
        if initial:
            status = subprocess.run(
                base + ["status", "--porcelain=v1", "--untracked-files=all", "--ignored"],
                capture_output=True, env=environment, timeout=5,
            )
            if status.returncode != 0 or status.stdout:
                return False
        return head.returncode == 0 and head.stdout.decode().strip() == spec["revision"] and clean.returncode == 0
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return False


def run(spec_path):
    spec_path = pathlib.Path(spec_path)
    spec = json.loads(spec_path.read_text())
    directory = spec_path.parent
    temporary = directory / "temporary"
    temporary.mkdir()
    libc = ctypes.CDLL(None, use_errno=True)
    # These receipts require Linux subreaper semantics. Unsupported hosts must
    # not fabricate descendant-stop proof.
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "cannot become a child subreaper")
    cancelled = False

    def cancel(_number, _frame):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    parent = os.getppid()
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "cannot watch the host process")
    if os.getppid() != parent:
        cancelled = True

    result = {
        "id": spec["id"],
        "candidate": spec["candidate"],
        "policy_sha": spec["policy_sha"],
        "command": spec["command"],
        "revision": spec["revision"],
        "timeout_ms": spec["timeout_ms"],
        "deadline_ms": spec["deadline_ms"],
        "exit_code": None,
        "reason": "launch_failed",
        "native_stop_confirmed": False,
    }
    output_path = directory / "output"
    started = time.monotonic()
    remaining = min(spec["timeout_ms"], spec["deadline_ms"] - int(time.time() * 1000))
    initial_snapshot = snapshot(spec, initial=True)
    digest = hashlib.sha256()
    size = 0
    process = None
    selector = selectors.DefaultSelector()
    try:
        with output_path.open("xb") as output:
            if not initial_snapshot:
                result["reason"] = "snapshot_changed"
                raise ValueError("candidate changed before launch")
            if cancelled or (directory / "cancel").exists():
                raise InterruptedError("cancelled before command allocation")
            if (time.monotonic() - started) * 1000 >= remaining:
                result["reason"] = "timeout"
                raise TimeoutError("budget expired before command allocation")
            process = subprocess.Popen(
                ["/bin/sh", "-c", spec["command"]],
                cwd=spec["workspace"],
                env={"PATH": ":".join(spec["path"]), "LANG": "C.UTF-8", "TMPDIR": str(temporary)},
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                preexec_fn=lambda: isolate(spec["workspace"], temporary, spec["git_directory"], spec["read_roots"] + spec["path"]),
            )
            atomic_json(directory / "native.json", {"supervisor_pid": os.getpid(), "command_pid": process.pid})
            os.set_blocking(process.stdout.fileno(), False)
            selector.register(process.stdout, selectors.EVENT_READ)
            result["reason"] = "completed"
            while True:
                if cancelled or (directory / "cancel").exists():
                    result["reason"] = "cancelled"
                    break
                if (time.monotonic() - started) * 1000 >= remaining:
                    result["reason"] = "timeout"
                    break
                for key, _ in selector.select(0.02):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    kept = data[: max(0, spec["max_output_bytes"] - size)]
                    output.write(kept)
                    digest.update(kept)
                    size += len(kept)
                    if len(kept) != len(data):
                        result["reason"] = "output_limit"
                        break
                if result["reason"] != "completed":
                    break
                if process.poll() is not None:
                    result["exit_code"] = process.returncode
                    # Background children cannot keep a successful shell's
                    # output stream open forever or outlive the check.
                    stop_children()
                    if not selector.get_map():
                        break
            output.flush()
            os.fsync(output.fileno())
    except InterruptedError:
        result["reason"] = "cancelled"
    except (OSError, ValueError, subprocess.SubprocessError):
        if result["reason"] not in ("snapshot_changed", "timeout"):
            result["reason"] = "supervisor_error"
    finally:
        if process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        result["native_stop_confirmed"] = stop_children()
        selector.close()
        if process is not None and process.stdout:
            process.stdout.close()
    result["elapsed_ms"] = int((time.monotonic() - started) * 1000)
    result["snapshot_valid"] = initial_snapshot and snapshot(spec)
    result["output_sha"] = digest.hexdigest()
    result["output_bytes"] = size
    atomic_json(directory / "receipt.json", result)


if __name__ == "__main__":
    run(sys.argv[1])
