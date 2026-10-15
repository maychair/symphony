#!/usr/bin/env python3
"""Export corrected facts from an immutable Codex rollout; never infer missing outcomes."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def git_value(cwd: str, *args: str) -> str | None:
    try:
        return subprocess.check_output(["git", "-C", cwd, *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def output_text(value: object) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(item.get("text", "") for item in value if isinstance(item, dict))
    return ""


def process_results(text: str) -> list[dict]:
    """Known JSON exec envelopes only; free-form text is not proof of an exit code."""
    results = []
    for line in text.splitlines():
        try:
            item = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(item, dict) or "wall_time_seconds" not in item:
            continue
        code = item.get("exit_code")
        if type(code) is int or item.get("session_id") is not None:
            results.append({"exit_code": code, "session_id": item.get("session_id"),
                            "source": "exec_result_envelope"})
    return results


def export(rollout: Path, run_file: Path | None = None) -> dict:
    meta, calls, outputs, turns, contexts = {}, {}, {}, set(), set()
    digest = hashlib.sha256()
    with rollout.open("rb") as stream:
        for line in stream:
            digest.update(line)
            entry = json.loads(line)
            data = entry.get("payload", {})
            if entry.get("type") == "session_meta":
                meta = data
            if entry.get("type") == "turn_context":
                if data.get("turn_id"):
                    turns.add(data["turn_id"])
                if data.get("cwd"):
                    contexts.add(data["cwd"])
            if entry.get("type") != "response_item":
                continue
            call_id = data.get("call_id")
            if data.get("type") in ("function_call", "custom_tool_call"):
                calls[call_id] = {"call_id": call_id, "tool": data.get("name"),
                                  "process_results": [], "transport_status": "unknown"}
            elif data.get("type") in ("function_call_output", "custom_tool_call_output"):
                outputs[call_id] = output_text(data.get("output"))
    for call_id, call in calls.items():
        text = outputs.get(call_id)
        if text is not None:
            # An output proves response delivery, not success of wrapped commands.
            call["transport_status"] = "response_received"
            call["process_results"] = process_results(text)
        call["process_status"] = ("failed" if any(type(r["exit_code"]) is int and r["exit_code"] != 0 for r in call["process_results"])
                                  else "success" if call["process_results"] and all(r["exit_code"] == 0 for r in call["process_results"]) else "unknown")
    cwd = meta.get("cwd")
    result = {"schema_version": 1, "thread_id": meta.get("id"), "turn_ids": sorted(turns),
              "source": str(rollout.resolve()), "source_sha256": digest.hexdigest(),
              "repository": {"cwd": cwd, "turn_cwds": sorted(contexts),
                             "commit": meta.get("git", {}).get("commit_hash"),
                             "branch": meta.get("git", {}).get("branch"),
                             "common_dir_observed": git_value(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir") if cwd else None,
                             "remote": git_value(cwd, "config", "--get", "remote.origin.url") if cwd else None,
                             "remote_provenance": "current_worktree_observation"},
              "calls": list(calls.values()), "cost_usd": None,
              "verification_status": "unknown", "review_links": [],
              "limitations": ["Only explicit structured exec exit codes are classified; nested text, pending sessions and unrecognized envelopes remain unknown.",
                              "Repository remote is observed now; historical commit and cwd come from the rollout.",
                              "No test gate, monetary cost or causal review relationship is inferred from tool names."]}
    if run_file:
        run_bytes = run_file.read_bytes()
        record = json.loads(run_bytes)
        if record.get("thread_id") != meta.get("id"):
            raise ValueError("Run journal does not belong to this rollout thread")
        result["run"] = {key: record.get(key) for key in (
            "issue_id", "attempt_id", "thread_id", "turn_id", "validation_policy", "validation_receipt")}
        result["run"]["source_sha256"] = hashlib.sha256(run_bytes).hexdigest()
        result["limitations"].append("Run journal is a current snapshot, not an attribution of all historical turns to its latest attempt.")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rollout", type=Path, required=True)
    parser.add_argument("--run-record", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = export(args.rollout, args.run_record)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    args.output.chmod(0o600)
    print(json.dumps({"output": str(args.output.resolve()), "calls": len(result["calls"]),
                      "process_failures": sum(c["process_status"] == "failed" for c in result["calls"]),
                      "process_unknown": sum(c["process_status"] == "unknown" for c in result["calls"])}))


if __name__ == "__main__":
    main()
