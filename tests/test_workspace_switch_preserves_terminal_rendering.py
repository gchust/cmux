#!/usr/bin/env python3
"""Regression: workspace switches must preserve visible terminal rendering.

Bug:
  - Switching away from a workspace and back could leave visible terminal panes blank/gray.
  - `surface_health` still reported the views as attached/in-window.
  - `refresh_surfaces` recovered the panes, which implies the terminal state was intact and
    the render pipeline was the part that stalled.

This test exercises the visual behavior directly:
  1. Create a split workspace with two visible terminal panes.
  2. Paint stable, cursor-hidden output into both panes and capture baseline snapshots.
  3. Switch to another workspace and back.
  4. Restore focus to the original pane so the active/inactive overlay state matches baseline.
  5. Capture new snapshots and assert the visual delta stays near baseline noise.

We use `panel_snapshot` instead of window screenshots to avoid Screen Recording permissions.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _ratio(changed_pixels: int, width: int, height: int) -> float:
    denom = max(1, int(width) * int(height))
    return float(max(0, int(changed_pixels))) / float(denom)


def _panel_snapshot_retry(c: cmux, panel_id: str, label: str, timeout_s: float = 3.0) -> dict:
    deadline = time.time() + timeout_s
    last_err: Exception | None = None
    while time.time() < deadline:
        try:
            return dict(c.panel_snapshot(panel_id, label=label) or {})
        except Exception as exc:
            last_err = exc
            if "Failed to capture panel image" not in str(exc):
                raise
            time.sleep(0.05)
    raise cmuxError(
        f"Timed out waiting for panel_snapshot panel_id={panel_id} label={label}: {last_err!r}"
    )


def _wait_panels_in_window(c: cmux, panel_ids: list[str], timeout_s: float = 5.0) -> None:
    deadline = time.time() + timeout_s
    last_health: dict[str, dict] = {}
    while time.time() < deadline:
        health_rows = c.surface_health()
        last_health = {str(row.get("id", "")).lower(): row for row in health_rows}
        if all(last_health.get(panel_id.lower(), {}).get("in_window") is True for panel_id in panel_ids):
            return
        time.sleep(0.05)
    raise cmuxError(f"panels never became visible in window: panel_ids={panel_ids} health={last_health}")


def _draw_stable_terminal(c: cmux, panel_id: str, label: str) -> None:
    cmd = (
        "printf '\\033[?25l\\033[2J\\033[H'; "
        f"for i in {{1..60}}; do printf '{label}_%02d\\n' \"$i\"; done\n"
    )
    c.send_surface(panel_id, cmd)


def _assert_snapshot_stable(
    baseline0: dict,
    baseline1: dict,
    after: dict,
    *,
    panel_id: str,
    label: str,
) -> None:
    width0 = int(baseline0.get("width") or 0)
    height0 = int(baseline0.get("height") or 0)
    width1 = int(baseline1.get("width") or 0)
    height1 = int(baseline1.get("height") or 0)
    width2 = int(after.get("width") or 0)
    height2 = int(after.get("height") or 0)
    dims = {(width0, height0), (width1, height1), (width2, height2)}
    if len(dims) != 1 or width0 <= 0 or height0 <= 0:
        raise cmuxError(
            "panel_snapshot dims differ across workspace switch.\n"
            f"  panel={panel_id} label={label}\n"
            f"  dims={dims}\n"
            f"  paths: {baseline0.get('path')} {baseline1.get('path')} {after.get('path')}"
        )

    noise_px = int(baseline1.get("changed_pixels") or 0)
    change_px = int(after.get("changed_pixels") or 0)
    if noise_px < 0 or change_px < 0:
        raise cmuxError(
            "panel_snapshot diff unavailable after workspace switch.\n"
            f"  panel={panel_id} label={label}\n"
            f"  noise_changed_pixels={noise_px}\n"
            f"  change_changed_pixels={change_px}\n"
            f"  paths: {baseline0.get('path')} {baseline1.get('path')} {after.get('path')}"
        )

    noise = _ratio(noise_px, width0, height0)
    change = _ratio(change_px, width0, height0)
    threshold = max(0.02, noise * 4.0 + 0.01)
    if change > threshold:
        raise cmuxError(
            "terminal rendering changed too much after workspace switch.\n"
            f"  panel={panel_id} label={label}\n"
            f"  noise_ratio={noise:.5f}\n"
            f"  change_ratio={change:.5f} threshold={threshold:.5f}\n"
            f"  snapshots: {baseline0.get('path')} {baseline1.get('path')} {after.get('path')}"
        )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        workspace_a = c.new_workspace()
        time.sleep(0.3)

        surfaces = c.list_surfaces()
        if not surfaces:
            raise cmuxError("expected initial terminal surface")
        left_panel = surfaces[0][1]

        right_panel = c.new_split("right")
        time.sleep(0.5)

        panel_ids = [left_panel, right_panel]
        _wait_panels_in_window(c, panel_ids)

        c.focus_surface(left_panel)
        time.sleep(0.2)

        for index, panel_id in enumerate(panel_ids):
            _draw_stable_terminal(c, panel_id, f"CMUX_WS_RENDER_{index}")
        time.sleep(0.5)

        for index, panel_id in enumerate(panel_ids):
            text = c.read_terminal_text(panel_id)
            marker = f"CMUX_WS_RENDER_{index}_60"
            if marker not in text:
                raise cmuxError(f"marker missing before switch for panel={panel_id}: {marker}")

        for panel_id in panel_ids:
            c.panel_snapshot_reset(panel_id)

        baselines: dict[str, tuple[dict, dict]] = {}
        for index, panel_id in enumerate(panel_ids):
            baseline0 = _panel_snapshot_retry(c, panel_id, f"ws_render_baseline0_{index}")
            time.sleep(0.2)
            baseline1 = _panel_snapshot_retry(c, panel_id, f"ws_render_baseline1_{index}")
            baselines[panel_id] = (baseline0, baseline1)

        workspace_b = c.new_workspace()
        time.sleep(0.3)

        for _ in range(2):
            c.select_workspace(workspace_a)
            time.sleep(0.35)
            c.select_workspace(workspace_b)
            time.sleep(0.2)

        c.select_workspace(workspace_a)
        time.sleep(0.45)
        _wait_panels_in_window(c, panel_ids)

        c.activate_app()
        c.focus_surface(left_panel)
        time.sleep(0.25)

        for index, panel_id in enumerate(panel_ids):
            after = _panel_snapshot_retry(c, panel_id, f"ws_render_after_{index}")
            baseline0, baseline1 = baselines[panel_id]
            _assert_snapshot_stable(
                baseline0,
                baseline1,
                after,
                panel_id=panel_id,
                label=f"panel{index}",
            )

        print("PASS: workspace switch preserves terminal rendering")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
