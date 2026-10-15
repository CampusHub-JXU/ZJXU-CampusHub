#!/usr/bin/env python3
"""Print a sanitized duration summary from a Dart VM Timeline JSON export."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path
from collections import Counter
from statistics import median
from typing import Any

GROUPS = {
    "build": {"BUILD"},
    "layout": {"LAYOUT"},
    "paint": {"PAINT"},
    "raster": {"GPURasterizer::Draw"},
    "frame": {"Animator::BeginFrame"},
}


def _event_durations(events: list[dict[str, Any]]) -> tuple[list[tuple[str, float, str, float]], dict[str, int]]:
    """Return completed trace event durations in milliseconds (Chrome trace X/B/E)."""
    pending: dict[tuple[str, str], list[tuple[str, str, float]]] = {}
    durations: list[tuple[str, float, str, float]] = []
    target_names = set().union(*GROUPS.values())
    diagnostics = {
        "unmatched_end": 0, "unmatched_begin": 0, "named_end_mismatch": 0,
        "target_unmatched_end": 0, "target_unmatched_begin": 0,
        "target_named_end_mismatch": 0,
    }
    ordered = sorted(
        enumerate(events),
        key=lambda pair: (float(pair[1].get("ts", 0) or 0), pair[0]),
    )
    for _, event in ordered:
        name = event.get("name")
        phase = event.get("ph")
        if phase == "X":
            if not isinstance(name, str):
                continue
            try:
                duration_us = float(event["dur"])
            except (KeyError, TypeError, ValueError):
                continue
            if duration_us >= 0:
                try:
                    start_us = float(event.get("ts", 0))
                except (TypeError, ValueError):
                    start_us = 0.0
                durations.append((name, duration_us / 1000.0, str(event.get("tid", "")), start_us))
        elif phase in ("B", "E"):
            key = (str(event.get("pid", "")), str(event.get("tid", "")))
            if phase == "B":
                if not isinstance(name, str):
                    continue
                try:
                    pending.setdefault(key, []).append((name, str(event.get("cat", "")), float(event["ts"])))
                except (KeyError, TypeError, ValueError):
                    continue
            else:
                try:
                    end = float(event["ts"])
                except (KeyError, TypeError, ValueError):
                    continue
                starts = pending.get(key)
                end_name = event.get("name")
                end_cat = str(event.get("cat", ""))
                matched_index = None
                if starts:
                    if isinstance(end_name, str) and end_name:
                        # Named Chrome E events pair by their trace identity,
                        # not by the last unrelated B on this thread. Different
                        # engine spans can overlap on a thread.
                        matched_index = next((i for i in range(len(starts) - 1, -1, -1)
                                              if starts[i][0] == end_name and starts[i][1] == end_cat), None)
                        # Some producers omit category on one half.
                        if matched_index is None and not end_cat:
                            matched_index = next((i for i in range(len(starts) - 1, -1, -1)
                                                  if starts[i][0] == end_name), None)
                        if matched_index is None:
                            diagnostics["named_end_mismatch"] += 1
                            # A pending target span on this thread does not make an
                            # unrelated named E a target mismatch. Instrumentation
                            # threads may have several nested/overlapping categories.
                            if end_name in target_names:
                                diagnostics["target_named_end_mismatch"] += 1
                    else:
                        # Nameless E is the Chrome nested-stack form.
                        matched_index = len(starts) - 1
                if matched_index is not None and starts is not None:
                    begin_name, _, start = starts.pop(matched_index)
                    if end >= start:
                        durations.append((begin_name, (end - start) / 1000.0, key[1], start))
                elif not starts:
                    diagnostics["unmatched_end"] += 1
                    if end_name in target_names:
                        diagnostics["target_unmatched_end"] += 1
    diagnostics["unmatched_begin"] = sum(len(stack) for stack in pending.values())
    diagnostics["target_unmatched_begin"] = sum(
        1 for stack in pending.values() for name, _, _ in stack if name in target_names
    )
    return durations, diagnostics


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    # Nearest-rank percentile, matching the app's performance report contract.
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def summarize(
    trace: dict[str, Any],
    window_start_us: float | None = None,
    window_end_us: float | None = None,
    window_label: str | None = None,
) -> dict[str, Any]:
    events = trace.get("events")
    if not isinstance(events, list):
        raise ValueError("trace must contain an events array")
    durations, pairing = _event_durations(events)
    if window_start_us is not None:
        durations = [item for item in durations if item[3] >= window_start_us]
    if window_end_us is not None:
        durations = [item for item in durations if item[3] < window_end_us]
    groups: dict[str, dict[str, Any]] = {}
    for group, needles in GROUPS.items():
        candidates = [item for item in durations if item[0] in needles]
        # Keep each phase on its own dominant VM thread so similarly named
        # events from a second isolate/thread cannot inflate the sample count.
        tids = Counter(item[2] for item in candidates)
        selected_tid = tids.most_common(1)[0][0] if tids else None
        selected = [item for item in candidates if item[2] == selected_tid]
        values = [item[1] for item in selected]
        starts = sorted(item[3] for item in selected if item[3] > 0)
        intervals = [(right - left) / 1000.0 for left, right in zip(starts, starts[1:]) if right >= left]
        groups[group] = {
            "count": len(values),
            "median_ms": median(values) if values else None,
            "p95_ms": _percentile(values, 0.95),
            "p99_ms": _percentile(values, 0.99),
            "max_ms": max(values) if values else None,
            "interval_ms": {
                "count": len(intervals),
                "median": _number(median(intervals)) if intervals else None,
                "p95": _percentile(intervals, 0.95),
                "max": max(intervals) if intervals else None,
                "above_16_67ms_count": sum(value > (1000 / 60) for value in intervals),
                "above_16_67ms_pct": round(
                    sum(value > (1000 / 60) for value in intervals) * 100 / len(intervals), 1
                ) if intervals else None,
            } if group == "frame" else None,
        }
    return {
        "scenario": _safe_label(trace.get("scenario")),
        "duration_ms": _number(trace.get("duration_us"), scale=1 / 1000),
        "capture_metadata": {
            "cold_start": trace.get("cold_start") is True,
            "build_mode": _safe_label(trace.get("build_mode")) if trace.get("build_mode") else "unknown",
            "vm_version": _safe_label(trace.get("vm_version")) if trace.get("vm_version") else "unknown",
            "target_cpu": _safe_label(trace.get("target_cpu")) if trace.get("target_cpu") else "unknown",
            "host_launch_to_first_drain_ms": _number(trace.get("host_launch_to_first_drain_ms")),
            "cpu_profile_requested": trace.get("cpu_profile_requested") is True,
            "cpu_profile_available": (
                isinstance(trace.get("cpu_profile"), dict)
                and trace["cpu_profile"].get("available") is not False
            ) if trace.get("cpu_profile_requested") is True else False,
            "cpu_sample_count": len(trace.get("cpu_profile", {}).get("samples", []))
            if isinstance(trace.get("cpu_profile"), dict)
            and isinstance(trace.get("cpu_profile", {}).get("samples"), list) else 0,
        },
        "completed_duration_events": len(durations),
        "pairing_diagnostics": pairing,
        "cpu_profile": _cpu_stack_summary(
            trace.get("cpu_profile"), window_start_us, window_end_us,
        ),
        "window": _safe_label(window_label) if window_label else "full-retained-trace",
        "groups": groups,
        "limitations": [
            "Build/Layout/Paint and Animator::BeginFrame are separate UI engine spans, not exclusive CPU time.",
            "GPURasterizer::Draw is an engine raster span, not measured GPU execution time; emulator values do not represent physical-device GPU cost.",
            "Missing event categories mean unavailable instrumentation, not zero work.",
        ],
    }


def _safe_label(value: Any) -> str:
    if not isinstance(value, str):
        return "unnamed"
    # Scenario labels are user supplied; keep only a small, non-identifying alphabet.
    safe = "".join(ch for ch in value if ch.isalnum() or ch in "-_ ")[:48].strip()
    return safe or "unnamed"


def _number(value: Any, scale: float = 1.0) -> float | None:
    try:
        number = float(value) * scale
    except (TypeError, ValueError):
        return None
    return round(number, 3) if math.isfinite(number) else None


def _cpu_stack_summary(profile: Any, start_us: float | None, end_us: float | None) -> dict[str, Any] | None:
    """Summarize VM sample stacks while omitting source URLs and paths."""
    if not isinstance(profile, dict) or not isinstance(profile.get("samples"), list):
        return None
    functions = profile.get("functions", [])
    if not isinstance(functions, list):
        functions = []

    def symbol(index: Any) -> str:
        try:
            item = functions[int(index)]
            raw = item.get("function", {}).get("name", "<unknown>")
        except (IndexError, TypeError, ValueError, AttributeError):
            raw = "<unknown>"
        if str(raw).startswith(("_Native_", "[Native]")):
            return "native-code"
        return re.sub(r"[^A-Za-z0-9_.$<>:/ -]", "_", str(raw))[:80].strip() or "<unknown>"

    stacks: Counter[tuple[str, ...]] = Counter()
    selected_samples = 0
    for sample in profile["samples"]:
        if not isinstance(sample, dict):
            continue
        try:
            timestamp = float(sample["timestamp"])
        except (KeyError, TypeError, ValueError):
            continue
        if start_us is not None and timestamp < start_us:
            continue
        if end_us is not None and timestamp >= end_us:
            continue
        stack = sample.get("stack")
        if not isinstance(stack, list) or not stack:
            continue
        stacks[tuple(symbol(index) for index in stack[:8])] += 1
        selected_samples += 1
    return {
        "sample_count": selected_samples,
        "profile_sample_count": len(profile["samples"]),
        "sample_period_us": _number(profile.get("samplePeriod")),
        "top_stacks": [
            {"samples": count,
             "share_pct": round(count * 100 / selected_samples, 1) if selected_samples else None,
             "stack": list(stack)}
            for stack, count in stacks.most_common(10)
        ],
        "limitations": [
            "VM CPU samples are statistical samples, not complete call counts or Android system CPU usage.",
            "Stacks are capped at eight frames and source URLs/paths are omitted.",
        ],
    }


def compare(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {"baseline": baseline["scenario"], "candidate": candidate["scenario"], "groups": {}}
    for group in GROUPS:
        metrics = {}
        for metric in ("median_ms", "p95_ms", "max_ms"):
            before = baseline["groups"][group][metric]
            after = candidate["groups"][group][metric]
            delta = None if before is None or after is None else round(after - before, 3)
            pct = None if before in (None, 0) or after is None else round((after / before - 1) * 100, 1)
            metrics[metric] = {"baseline": before, "candidate": after, "delta_ms": delta, "change_pct": pct}
        result["groups"][group] = metrics
    result["note"] = "Positive duration change means slower spans; compare repeated runs under matching conditions."
    return result


def _load(path: str) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _selected_summary(
    path: str,
    action_name: str | None,
    window_ms: str | None,
    action_window_ms: str | None,
    startup_3s: bool,
) -> dict[str, Any]:
    trace = _load(path)
    if sum(bool(value) for value in (action_name, window_ms, action_window_ms, startup_3s)) > 1:
        raise ValueError("choose only one trace window selector")
    start_us = end_us = None
    label = None
    events = trace.get("events", [])
    capture_start = trace.get("capture_start_us")
    anchor = float(capture_start) if capture_start is not None else min(
        (float(e["ts"]) for e in events if isinstance(e, dict) and e.get("ts") is not None),
        default=0.0,
    )
    anchor_description = "capture-start" if capture_start is not None else "first-retained-event"
    if action_name:
        actions = trace.get("actions", [])
        matches = [i for i, action in enumerate(actions) if action.get("name") == action_name]
        if not matches:
            raise ValueError(f"no action named {action_name!r} in trace metadata")
        index = matches[0]
        action = actions[index]
        start_us = float(action["start_us"])
        if index + 1 < len(actions):
            end_us = float(actions[index + 1]["start_us"])
        elif trace.get("capture_end_us") is not None:
            end_us = float(trace["capture_end_us"])
        label = f"after-{action_name}"
        anchor_description = f"action:{action_name}"
    if action_window_ms:
        pieces = action_window_ms.split(":")
        if len(pieces) != 3:
            raise ValueError("--action-window-ms format is NAME:START:END")
        name, begin_ms, finish_ms = pieces
        actions = trace.get("actions", [])
        action = next((item for item in actions if item.get("name") == name), None)
        if action is None:
            raise ValueError(f"no action named {name!r} in trace metadata")
        action_start = float(action["start_us"])
        start_us = action_start + float(begin_ms) * 1000
        end_us = action_start + float(finish_ms) * 1000
        label = f"{name}-{begin_ms}-{finish_ms}ms"
        anchor_description = f"action:{name}"
    if startup_3s:
        first_frame = min(
            (float(e["ts"]) for e in events
             if isinstance(e, dict) and e.get("name") == "Animator::BeginFrame" and e.get("ph") == "B" and e.get("ts") is not None),
            default=None,
        )
        if first_frame is None:
            raise ValueError("trace contains no Animator::BeginFrame start event")
        start_us = first_frame
        end_us = first_frame + 3_000_000
        label = "first-3000ms-from-animator-frame"
        anchor_description = "first-Animator::BeginFrame"
    if window_ms:
        pieces = window_ms.split(":")
        if len(pieces) != 2:
            raise ValueError("--window-ms format is START:END")
        start_us = anchor + float(pieces[0]) * 1000
        end_us = anchor + float(pieces[1]) * 1000
        label = f"window-{pieces[0]}-{pieces[1]}ms"
        anchor_description = "capture-start" if capture_start is not None else "first-retained-event"
    summary = summarize(trace, start_us, end_us, label)
    summary["window_anchor"] = anchor_description
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", nargs="?", help="VM Timeline JSON captured by capture_timeline.dart")
    parser.add_argument("--baseline", help="baseline trace for a paired comparison")
    parser.add_argument("--candidate", help="candidate trace for a paired comparison")
    parser.add_argument("--action", help="analyze from a named action marker to the next action/end")
    parser.add_argument("--window-ms", help="analyze a relative capture window START:END")
    parser.add_argument("--action-window-ms", help="analyze a window NAME:START:END relative to an action marker")
    parser.add_argument("--startup-3s", action="store_true", help="analyze first 3000ms from first Animator::BeginFrame")
    args = parser.parse_args()
    try:
        if args.baseline or args.candidate:
            if not args.baseline or not args.candidate or args.trace:
                parser.error("provide both --baseline and --candidate, without positional trace")
            output = compare(
                _selected_summary(args.baseline, args.action, args.window_ms, args.action_window_ms, args.startup_3s),
                _selected_summary(args.candidate, args.action, args.window_ms, args.action_window_ms, args.startup_3s),
            )
        elif args.trace:
            output = _selected_summary(args.trace, args.action, args.window_ms, args.action_window_ms, args.startup_3s)
        else:
            parser.error("provide a trace or a baseline/candidate pair")
        print(json.dumps(output, indent=2, sort_keys=True))
        return 0
    except (OSError, json.JSONDecodeError, ValueError) as error:
        parser.exit(2, f"Trace analysis failed: {error}\n")


if __name__ == "__main__":
    raise SystemExit(main())
