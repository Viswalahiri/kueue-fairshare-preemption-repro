#!/usr/bin/env python3
"""Derive a grace-period timeline from raw capture files in one grace run directory.

This is not a unit test and it is not kubectl output. The capture script
writes a DERIVED header around this script's stdout.
"""

from __future__ import annotations

import re
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from capture_json import load_capture_text


def parse_ts(value: str | None):
    if value is None:
        return None
    text = value.strip()
    if text in ("", "<none>", "<nil>", "null"):
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    if "." in text:
        head, rest = text.split(".", 1)
        frac, tail = rest, ""
        for i, ch in enumerate(rest):
            if not ch.isdigit():
                frac, tail = rest[:i], rest[i:]
                break
        text = head + "." + frac[:6] + tail
    return datetime.fromisoformat(text)


def cond_fields(text: str, typ: str):
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4 and parts[0] == typ:
            return parts[1].strip(), parts[2].strip(), parts[3].strip()
    return None, None, None


def main() -> None:
    directory = Path(sys.argv[1])
    lines: list[str] = []
    victim_text = load_capture_text(directory / "victim-conditions.txt") if (directory / "victim-conditions.txt").exists() else ""
    preemptor_text = load_capture_text(directory / "preemptor-conditions.txt") if (directory / "preemptor-conditions.txt").exists() else ""
    ev_status, ev_reason, ev_time = cond_fields(victim_text, "Evicted")
    ad_status, ad_reason, ad_time = cond_fields(preemptor_text, "Admitted")
    lines.append(f"evicted_status: {ev_status or '<missing>'}")
    lines.append(f"evicted_reason: {ev_reason or '<missing>'}")
    lines.append(f"evicted_lastTransitionTime: {ev_time or '<missing>'}")
    lines.append(f"admitted_status: {ad_status or '<missing>'}")
    lines.append(f"admitted_reason: {ad_reason or '<missing>'}")
    lines.append(f"admitted_lastTransitionTime: {ad_time or '<missing>'}")
    ev_dt = parse_ts(ev_time)
    ad_dt = parse_ts(ad_time)
    if ev_dt and ad_dt:
        lines.append(f"delta_evicted_to_admitted_seconds: {(ad_dt - ev_dt).total_seconds():.0f}")

    watch_path = directory / "pods-all-watch.txt"
    if not watch_path.exists():
        watch_path = directory / "pod-watch.txt"
    watch = load_capture_text(watch_path) if watch_path.exists() else ""
    polls: list[tuple[str, list[str]]] = []
    current_time: str | None = None
    current_rows: list[str] = []
    deletion_mode = False

    def flush() -> None:
        if current_time is not None and deletion_mode:
            polls.append((current_time, list(current_rows)))

    for line in watch.splitlines():
        if line.startswith("DELETION_POLL "):
            flush()
            deletion_mode = True
            current_time = line.split(" ", 1)[1].strip()
            current_rows = []
        elif line.startswith("POLL "):
            flush()
            deletion_mode = False
            current_time = line.split(" ", 1)[1].strip()
            current_rows = []
        elif line.startswith("POD_GONE "):
            flush()
            deletion_mode = False
            current_time = None
            current_rows = []
            lines.append("pod_gone: " + line.split(" ", 1)[1].strip())
        elif line.startswith("WATCH_TIMEOUT "):
            lines.append("watch_timeout: " + line.split(" ", 1)[1].strip())
        elif (
            line.startswith("POD_COUNT ")
            or line.startswith("VICTIM_POD_COUNT ")
            or line.startswith("NAME")
            or line.startswith("NAMESPACE")
            or line.startswith("NS ")
            or line.startswith("No resources")
        ):
            continue
        elif deletion_mode and current_time is not None and line.strip():
            current_rows.append(line)
    flush()

    victim_name = None
    spec_path = directory / "pod-spec.txt"
    if spec_path.exists():
        for line in load_capture_text(spec_path).splitlines():
            if line.startswith("pod:"):
                victim_name = line.split(":", 1)[1].strip()
                break

    def is_victim(ns: str, name: str) -> bool:
        # The ~9s sample is the preempted job's pod. The poll lists every
        # pod in the cluster, and coredns is first, so an unfiltered pick
        # reports coredns.
        if victim_name:
            return name == victim_name
        return name.startswith("b3-") and ns in ("", "team-b")

    first_deletion = None
    nearest_9 = None
    for poll_time, rows in polls:
        poll_dt = parse_ts(poll_time)
        for row in rows:
            cols = [part for part in re.split(r"\s{2,}", row.strip()) if part]
            if len(cols) >= 4:
                ns, name, phase, deletion = cols[0], cols[1], cols[2], cols[3]
            elif len(cols) >= 3:
                ns, name, phase, deletion = "", cols[0], cols[1], cols[2]
            else:
                continue
            if deletion not in ("<none>", "<nil>") and first_deletion is None:
                first_deletion = (poll_time, name, phase, deletion)
            if is_victim(ns, name) and ev_dt and poll_dt:
                delta = (poll_dt - ev_dt).total_seconds()
                if nearest_9 is None or abs(delta - 9) < abs(nearest_9[0] - 9):
                    nearest_9 = (delta, poll_time, name, phase, deletion)
    if first_deletion:
        lines.append(
            "first_deletionTimestamp_poll: "
            f"{first_deletion[0]} pod={first_deletion[1]} phase={first_deletion[2]} deletionTimestamp={first_deletion[3]}"
        )
    else:
        lines.append("first_deletionTimestamp_poll: <none>")
    if nearest_9:
        lines.append(
            "poll_nearest_9s_after_evicted: "
            f"delta_seconds={nearest_9[0]:.3f} poll={nearest_9[1]} pod={nearest_9[2]} "
            f"phase={nearest_9[3]} deletionTimestamp={nearest_9[4]}"
        )
    else:
        lines.append("poll_nearest_9s_after_evicted: <none>")
    lines.append("polls:")
    for poll_time, rows in polls:
        poll_dt = parse_ts(poll_time)
        delta = ""
        if ev_dt and poll_dt:
            delta = f" delta_after_evicted_s={(poll_dt - ev_dt).total_seconds():.3f}"
        if not rows:
            lines.append(f"  {poll_time}{delta} rows=0")
        for row in rows:
            lines.append(f"  {poll_time}{delta} {row}")
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
