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


def native_operation(data: dict, line_number: int) -> dict:
    item = data["item"]
    verification = None
    if item.get("tool") in ("beads_validate", "beads_deliver"):
        for content in item.get("content_items", []):
            try:
                value = json.loads(content.get("text", ""))
            except (ValueError, TypeError):
                continue
            if isinstance(value, dict):
                receipt = value.get("validation_receipt", value)
                if isinstance(receipt, dict) and type(receipt.get("passed")) is bool:
                    verification = {key: receipt.get(key) for key in ("passed", "identity", "attempt_id", "policy", "results")}
    return {"verification": verification, "native_item_id": item["id"], "thread_id": data.get("thread_id"),
            "turn_id": data.get("turn_id"), "type": item["type"], "tool": item.get("tool"),
            "argv": item.get("command"), "cwd": item.get("cwd"), "arguments": item.get("arguments"),
            "exit_code": item.get("exit_code"), "tool_success": item.get("success"),
            "native_status": item.get("status"), "started_at_ms": data.get("started_at_ms"),
            "completed_at_ms": data.get("completed_at_ms"), "source_line": line_number,
            "provenance": "native_item_completed"}


def write_otlp(result: dict, destination: Path) -> None:
    """OpenInference JSONL spans with observed identities; missing causal links stay missing."""
    def identity(value: str, size: int = 16) -> str:
        return hashlib.sha256(value.encode()).hexdigest()[:size]

    thread = result["thread_id"] or result["source_sha256"]
    trace = identity(thread, 32)
    root_id = identity(thread + ":session")
    bounds = result["turn_boundaries"]
    root_attrs = {"openinference.span.kind": "AGENT", "session.id": thread,
                  "source.sha256": result["source_sha256"], "source.path": result["source"],
                  "tool.wrapper_call_count": len(result["calls"])}
    usage = result.get("token_usage", {})
    if usage:
        root_attrs.update({"gen_ai.usage.input_tokens": usage.get("input_tokens", 0) - usage.get("cached_input_tokens", 0),
                           "gen_ai.usage.output_tokens": usage.get("output_tokens", 0),
                           "gen_ai.usage.cache_read_input_tokens": usage.get("cached_input_tokens", 0)})
    if len(result.get("models", [])) == 1:
        root_attrs["gen_ai.request.model"] = result["models"][0]
    for key in ("recovery_cause", "trigger_actor", "caused_by_event"):
        value = result.get("run", {}).get(key)
        if value is not None:
            root_attrs["run." + key] = value
    resources = {"service.name": "symphony", "git.repository": result["repository"]["remote"],
                 "git.commit": result["repository"]["commit"], "tangle.cwd": result["repository"]["cwd"]}
    common = {"trace_id": trace, "resource": {"attributes": {k: v for k, v in resources.items() if v is not None}},
              "scope": {"name": "symphony.native-session-evidence", "version": "2"}}
    spans = [{**common, "span_id": root_id, "parent_span_id": "", "name": "session", "kind": "AGENT",
              "start_time": bounds[0]["at"] if bounds else None, "end_time": bounds[-1]["at"] if bounds else None,
              "status": {"code": "STATUS_CODE_UNSET"}, "attributes": root_attrs}]
    turns = {item["turn_id"]: index + 1 for index, item in enumerate(item for item in bounds if item["type"] == "task_started")}
    native_spans = {op["native_item_id"]: identity(str(op["thread_id"]) + ":" + str(op["turn_id"]) + ":" + op["native_item_id"])
                    for op in result["native_operations"]}
    for op in result["native_operations"]:
        name = op["tool"] or ("exec_command" if op["type"] == "CommandExecution" else "file_change")
        failed = op["tool_success"] is False or (type(op["exit_code"]) is int and op["exit_code"] != 0)
        known = type(op["tool_success"]) is bool or type(op["exit_code"]) is int
        attrs = {"openinference.span.kind": "TOOL", "tool.name": name, "session.id": op["thread_id"],
                 "native.item_id": op["native_item_id"], "native.turn_id": op["turn_id"],
                 "input.value": json.dumps(op["argv"] or op["arguments"] or {}),
                 "output.value": json.dumps({"exit_code": op["exit_code"], "success": op["tool_success"]}),
                 "evidence.source_line": op["source_line"], "evidence.provenance": op["provenance"]}
        if op.get("verification"):
            attrs["verification.passed"] = op["verification"]["passed"]
            attrs["verification.receipt"] = json.dumps(op["verification"])
        if op["turn_id"] in turns:
            attrs["agent.loop.iteration"] = turns[op["turn_id"]]
        if op["cwd"] is not None:
            attrs["process.cwd"] = op["cwd"]
        if op["exit_code"] is not None:
            attrs["process.exit_code"] = op["exit_code"]
        if op["tool_success"] is not None:
            attrs["tool.success"] = op["tool_success"]
        links = []
        run = result.get("run", {})
        cause = run.get("caused_by_event")
        if op["turn_id"] == run.get("turn_id") and isinstance(cause, str) and cause in native_spans:
            links = [{"trace_id": trace, "span_id": native_spans[cause]}]
        spans.append({**common, "links": links, "span_id": identity(str(op["thread_id"]) + ":" + str(op["turn_id"]) + ":" + op["native_item_id"]),
                      "parent_span_id": root_id if op["thread_id"] == result["thread_id"] else "",
                      "name": "tool." + name, "kind": "TOOL", "start_time": iso_millis(op["started_at_ms"]),
                      "end_time": iso_millis(op["completed_at_ms"]),
                      "status": {"code": "STATUS_CODE_ERROR" if failed else "STATUS_CODE_OK" if known else "STATUS_CODE_UNSET"},
                      "attributes": {k: v for k, v in attrs.items() if v is not None}})
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("".join(json.dumps(span, ensure_ascii=False) + "\n" for span in spans))
    destination.chmod(0o600)


def iso_millis(value: int | None) -> str | None:
    if value is None:
        return None
    from datetime import datetime, timezone
    return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat().replace("+00:00", "Z")


def export(rollout: Path, run_file: Path | None = None) -> dict:
    meta, calls, outputs, turns, contexts = {}, {}, {}, set(), set()
    operations = {}
    boundaries = []
    usage = {}
    models = set()
    digest = hashlib.sha256()
    with rollout.open("rb") as stream:
        for line_number, line in enumerate(stream, 1):
            digest.update(line)
            entry = json.loads(line)
            data = entry.get("payload", {})
            if entry.get("type") == "session_meta":
                meta = data
            if entry.get("type") == "token_usage_record":
                for key, value in data.get("usage", {}).items():
                    if type(value) is int:
                        usage[key] = usage.get(key, 0) + value
            if entry.get("type") == "turn_context":
                if data.get("model"):
                    models.add(data["model"])
                if data.get("turn_id"):
                    turns.add(data["turn_id"])
                if data.get("cwd"):
                    contexts.add(data["cwd"])
            if entry.get("type") == "event_msg" and data.get("type") in ("task_started", "task_complete"):
                boundaries.append({"type": data["type"], "turn_id": data.get("turn_id"),
                                   "at": entry.get("timestamp"), "duration_ms": data.get("duration_ms")})
            if entry.get("type") == "event_msg" and data.get("type") == "item_completed":
                item = data.get("item", {})
                if item.get("type") in ("CommandExecution", "DynamicToolCall", "FileChange") and item.get("id"):
                    op = native_operation(data, line_number)
                    operations[(op["thread_id"], op["turn_id"], op["native_item_id"])] = op
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
    result = {"schema_version": 2, "thread_id": meta.get("id"), "turn_ids": sorted(turns),
              "source": str(rollout.resolve()), "source_sha256": digest.hexdigest(),
              "repository": {"cwd": cwd, "turn_cwds": sorted(contexts),
                             "commit": meta.get("git", {}).get("commit_hash"),
                             "branch": meta.get("git", {}).get("branch"),
                             "common_dir_observed": git_value(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir") if cwd else None,
                             "remote": git_value(cwd, "config", "--get", "remote.origin.url") if cwd else None,
                             "remote_provenance": "current_worktree_observation"},
              "calls": list(calls.values()), "native_operations": list(operations.values()),
              "turn_boundaries": boundaries, "token_usage": usage, "models": sorted(models), "cost_usd": None,
              "verification_status": "unknown", "review_links": [],
              "limitations": ["Only explicit structured exec exit codes are classified; nested text, pending sessions and unrecognized envelopes remain unknown.",
                              "Repository remote is observed now; historical commit and cwd come from the rollout.",
                              "No test gate, monetary cost or causal review relationship is inferred from tool names."]}
    result["verification_observations"] = [op["verification"] for op in operations.values() if op.get("verification")]
    if result["verification_observations"]:
        result["verification_status"] = "passed_observed" if result["verification_observations"][-1]["passed"] else "failed_observed"
    result["native_counts"] = {
        "commands": sum(op["type"] == "CommandExecution" for op in operations.values()),
        "host_tools": sum(op["type"] == "DynamicToolCall" for op in operations.values()),
        "host_tool_failures": sum(op["type"] == "DynamicToolCall" and op["tool_success"] is False for op in operations.values()),
        "process_failures": sum(type(op["exit_code"]) is int and op["exit_code"] != 0 for op in operations.values()),
    }
    result["limitations"].append("Native operations and wrapper calls are distinct inventories, not additive counts; incomplete native events retain wrapper fallback with provenance.")
    if run_file:
        run_bytes = run_file.read_bytes()
        record = json.loads(run_bytes)
        if record.get("thread_id") != meta.get("id"):
            raise ValueError("Run journal does not belong to this rollout thread")
        result["run"] = {key: record.get(key) for key in (
            "issue_id", "attempt_id", "thread_id", "turn_id", "validation_policy", "validation_receipt",
            "recovery_cause", "trigger_actor", "caused_by_event", "repair_count", "runtime_recovery_count")}
        result["run"]["source_sha256"] = hashlib.sha256(run_bytes).hexdigest()
        result["limitations"].append("Run journal is a current snapshot, not an attribution of all historical turns to its latest attempt.")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rollout", type=Path, required=True)
    parser.add_argument("--run-record", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--otlp-out", type=Path, help="optional private native-event OpenInference JSONL")
    args = parser.parse_args()
    result = export(args.rollout, args.run_record)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    args.output.chmod(0o600)
    if args.otlp_out:
        write_otlp(result, args.otlp_out)
    print(json.dumps({"output": str(args.output.resolve()), "calls": len(result["calls"]),
                      "process_failures": sum(c["process_status"] == "failed" for c in result["calls"]),
                      "process_unknown": sum(c["process_status"] == "unknown" for c in result["calls"])}))


if __name__ == "__main__":
    main()
