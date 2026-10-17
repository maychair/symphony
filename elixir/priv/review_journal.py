"""Kernel-locked journal transport. Runtime ownership receipts are never tasks."""

import fcntl
import json
import os
from pathlib import Path
import struct
import sys


def emit(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    sys.stdout.buffer.write(struct.pack("!I", len(data)) + data)
    sys.stdout.buffer.flush()


def receive():
    header = sys.stdin.buffer.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise ValueError("truncated request header")
    length = struct.unpack("!I", header)[0]
    data = sys.stdin.buffer.read(length)
    if len(data) != length:
        raise ValueError("truncated request body")
    return json.loads(data)


def start_time(pid):
    # comm may contain spaces and closing parentheses; fields after its final
    # delimiter start at field 3, with starttime at field 22.
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    return str(int(fields[19]))


def process_identity():
    # Erlang may spawn ports through erl_child_setup, so getppid() is not
    # the controller. The owning BEAM passes its own OS PID explicitly.
    pid = str(int(sys.argv[2]))
    return {
        "machine": Path("/etc/machine-id").read_text().strip(),
        "boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
        "namespace": os.readlink("/proc/self/ns/pid"),
        "pid": pid,
        "start": start_time(pid),
    }


def process_state(previous, current):
    if not isinstance(previous, dict) or set(previous) != set(current):
        return "unknown"
    if any(previous[key] != current[key] for key in ("machine", "boot", "namespace")):
        return "unknown"
    if not all(isinstance(previous[key], str) and previous[key].isdigit() for key in ("pid", "start")):
        return "unknown"
    try:
        return "alive" if start_time(previous["pid"]) == previous["start"] else "stopped"
    except FileNotFoundError:
        return "stopped"
    except (OSError, ValueError, IndexError):
        return "unknown"


def write_synced(directory, name, body):
    temporary = directory / (name + ".pending")
    with temporary.open("w", encoding="utf-8") as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, directory / name)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def serve(directory, lock):
    identity = process_identity()
    owner_path = directory / "review-journal-owner.json"
    journal_path = directory / "review-lane.json"
    previous = json.loads(owner_path.read_text()) if owner_path.exists() else None
    if previous is None and journal_path.exists():
        raise ValueError("review_journal_owner_missing_migration_required")
    status = process_state(previous.get("process"), identity) if isinstance(previous, dict) else "unknown"
    emit({"ok": {"previous": previous, "process_state": status}})
    owner = None

    while (request := receive()) is not None:
        # The lock inode is permanent. Never silently keep writing a detached
        # inode after external removal or replacement of the lock path.
        current = (directory / "review-journal.lock").stat()
        held = os.fstat(lock.fileno())
        if (current.st_dev, current.st_ino) != (held.st_dev, held.st_ino):
            raise ValueError("review_journal_lock_replaced")
        operation = request.get("op")
        if operation == "claim" and owner is None:
            owner = {"schema_version": 1, "listener": request["listener"], "process": identity, "released": False}
            write_synced(directory, owner_path.name, json.dumps(owner))
            emit({"ok": True})
        elif owner is None:
            raise ValueError("review_journal_not_claimed")
        elif operation == "read":
            emit({"ok": journal_path.read_text() if journal_path.exists() else None})
        elif operation == "write" and isinstance(request.get("body"), str):
            write_synced(directory, journal_path.name, request["body"])
            emit({"ok": True})
        elif operation == "check":
            emit({"ok": True})
        elif operation == "release":
            owner["released"] = True
            write_synced(directory, owner_path.name, json.dumps(owner))
            fcntl.flock(lock, fcntl.LOCK_UN)
            emit({"ok": True})
            return
        else:
            raise ValueError("invalid_review_journal_operation")
    # EOF is not a clean controller release. Keep the owner receipt so the next
    # controller must prove that its predecessor actually exited.


def main():
    directory = Path(sys.argv[1])
    try:
        with (directory / "review-journal.lock").open("a+b") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                emit({"error": "review_journal_locked"})
                return
            serve(directory, lock)
    except BrokenPipeError:
        pass
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        try:
            emit({"error": str(error)})
        except BrokenPipeError:
            pass


if __name__ == "__main__":
    main()
