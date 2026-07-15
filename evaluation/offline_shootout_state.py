#!/usr/bin/env python3
"""Persist offline arm shootout results and winner selection."""

from __future__ import annotations

import argparse
from pathlib import Path

from json_state_utils import atomic_write_json, load_json, utc_now_iso


STATE_VERSION = 1


def _load_state(path: Path) -> dict:
    return load_json(path)


def cmd_init(args: argparse.Namespace) -> int:
    path = Path(args.state)
    selected_arm_ids = [int(arm_id) for arm_id in args.arm_ids]
    arm_names = list(args.arm_names)
    if len(selected_arm_ids) != len(arm_names):
        raise ValueError("arm-ids and arm-names must have the same length")

    state = {
        "version": STATE_VERSION,
        "mode": "offline_shootout",
        "design_name": args.design_name,
        "budget_sec": int(args.budget_sec),
        "created_utc": utc_now_iso(),
        "updated_utc": utc_now_iso(),
        "selected_arm_ids": selected_arm_ids,
        "arm_names": arm_names,
        "baseline": {
            "wns": float(args.baseline_wns),
            "tns": float(args.baseline_tns),
            "area": float(args.baseline_area),
            "slew": float(args.baseline_slew),
        },
        "arms": [],
        "winner": None,
    }
    atomic_write_json(path, state)
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    path = Path(args.state)
    state = _load_state(path)

    arm_id = int(args.arm_id)
    selected_arm_ids = [int(item) for item in state.get("selected_arm_ids", [])]
    if arm_id not in selected_arm_ids:
        raise ValueError(f"arm_id out of range: {arm_id}")

    record = {
        "arm_id": arm_id,
        "arm_name": args.arm_name,
        "iterations": int(args.iterations),
        "elapsed_sec": int(args.elapsed_sec),
        "reward": float(args.reward),
        "legalization_events": int(args.legalization_events),
        "arm_errors": int(args.arm_errors),
        "final": {
            "wns": float(args.final_wns),
            "tns": float(args.final_tns),
            "area": float(args.final_area),
            "slew": float(args.final_slew),
        },
        "deltas": {
            "wns_pct": float(args.wns_pct),
            "tns_pct": float(args.tns_pct),
            "area_pct": float(args.area_pct),
            "slew_pct": float(args.slew_pct),
        },
    }

    filtered = [r for r in state["arms"] if int(r["arm_id"]) != arm_id]
    filtered.append(record)
    filtered.sort(key=lambda r: int(r["arm_id"]))
    state["arms"] = filtered
    state["updated_utc"] = utc_now_iso()

    atomic_write_json(path, state)
    return 0


def cmd_record_final(args: argparse.Namespace) -> int:
    path = Path(args.state)
    state = _load_state(path)

    arm_id = int(args.arm_id)
    selected_arm_ids = [int(item) for item in state.get("selected_arm_ids", [])]
    if arm_id not in selected_arm_ids:
        raise ValueError(f"arm_id out of range: {arm_id}")

    baseline = state["baseline"]
    base_wns = float(baseline["wns"])
    base_tns = float(baseline["tns"])
    base_area = float(baseline["area"])
    base_slew = float(baseline["slew"])

    final_wns = float(args.final_wns)
    final_tns = float(args.final_tns)
    final_area = float(args.final_area)
    final_slew = float(args.final_slew)

    def pct_improvement(before: float, after: float) -> float:
        denom = abs(before)
        if denom < 1e-9:
            denom = 1.0
        return (after - before) / denom

    def pct_reduction(before: float, after: float) -> float:
        denom = abs(before)
        if denom < 1e-9:
            denom = 1.0
        return (before - after) / denom

    wns_pct = pct_improvement(base_wns, final_wns)
    tns_pct = pct_improvement(base_tns, final_tns)
    area_pct = pct_improvement(base_area, final_area)
    slew_pct = pct_reduction(base_slew, final_slew)

    area_penalty = area_pct if area_pct > 0.0 else 0.0
    legalization_events = int(args.legalization_events)
    legalization_penalty = 1.0 if legalization_events > 0 else 0.0

    reward = 0.35 * wns_pct + 0.35 * tns_pct + 0.20 * slew_pct - 0.08 * area_penalty - 0.02 * legalization_penalty

    record = {
        "arm_id": arm_id,
        "arm_name": args.arm_name,
        "iterations": int(args.iterations),
        "elapsed_sec": int(args.elapsed_sec),
        "reward": float(reward),
        "legalization_events": legalization_events,
        "arm_errors": int(args.arm_errors),
        "final": {
            "wns": final_wns,
            "tns": final_tns,
            "area": final_area,
            "slew": final_slew,
        },
        "deltas": {
            "wns_pct": float(wns_pct),
            "tns_pct": float(tns_pct),
            "area_pct": float(area_pct),
            "slew_pct": float(slew_pct),
        },
    }

    filtered = [r for r in state["arms"] if int(r["arm_id"]) != arm_id]
    filtered.append(record)
    filtered.sort(key=lambda r: int(r["arm_id"]))
    state["arms"] = filtered
    state["updated_utc"] = utc_now_iso()

    atomic_write_json(path, state)
    print(f"{reward:.6f}")
    return 0


def cmd_finalize(args: argparse.Namespace) -> int:
    path = Path(args.state)
    state = _load_state(path)

    if not state["arms"]:
        raise ValueError("no arm results recorded")

    winner = max(state["arms"], key=lambda r: float(r["reward"]))
    state["winner"] = winner
    state["updated_utc"] = utc_now_iso()
    atomic_write_json(path, state)

    winner_path = Path(args.winner_out)
    winner_obj = {
        "version": STATE_VERSION,
        "mode": "offline_shootout_winner",
        "design_name": state["design_name"],
        "budget_sec": state["budget_sec"],
        "selected_utc": utc_now_iso(),
        "winner": winner,
    }
    atomic_write_json(winner_path, winner_obj)

    print(str(winner["arm_id"]))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Offline shootout JSON persistence")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="initialize shootout state")
    p_init.add_argument("--state", required=True)
    p_init.add_argument("--design-name", required=True)
    p_init.add_argument("--budget-sec", required=True, type=int)
    p_init.add_argument("--arm-ids", required=True, nargs="+", type=int)
    p_init.add_argument("--arm-names", required=True, nargs="+")
    p_init.add_argument("--baseline-wns", required=True, type=float)
    p_init.add_argument("--baseline-tns", required=True, type=float)
    p_init.add_argument("--baseline-area", required=True, type=float)
    p_init.add_argument("--baseline-slew", required=True, type=float)
    p_init.set_defaults(func=cmd_init)

    p_record = sub.add_parser("record", help="record one arm result")
    p_record.add_argument("--state", required=True)
    p_record.add_argument("--arm-id", required=True, type=int)
    p_record.add_argument("--arm-name", required=True)
    p_record.add_argument("--iterations", required=True, type=int)
    p_record.add_argument("--elapsed-sec", required=True, type=int)
    p_record.add_argument("--reward", required=True, type=float)
    p_record.add_argument("--legalization-events", required=True, type=int)
    p_record.add_argument("--arm-errors", required=True, type=int)
    p_record.add_argument("--final-wns", required=True, type=float)
    p_record.add_argument("--final-tns", required=True, type=float)
    p_record.add_argument("--final-area", required=True, type=float)
    p_record.add_argument("--final-slew", required=True, type=float)
    p_record.add_argument("--wns-pct", required=True, type=float)
    p_record.add_argument("--tns-pct", required=True, type=float)
    p_record.add_argument("--area-pct", required=True, type=float)
    p_record.add_argument("--slew-pct", required=True, type=float)
    p_record.set_defaults(func=cmd_record)

    p_record_final = sub.add_parser("record-final", help="record final arm metrics and compute reward from baseline")
    p_record_final.add_argument("--state", required=True)
    p_record_final.add_argument("--arm-id", required=True, type=int)
    p_record_final.add_argument("--arm-name", required=True)
    p_record_final.add_argument("--iterations", required=True, type=int)
    p_record_final.add_argument("--elapsed-sec", required=True, type=int)
    p_record_final.add_argument("--legalization-events", required=True, type=int)
    p_record_final.add_argument("--arm-errors", required=True, type=int)
    p_record_final.add_argument("--final-wns", required=True, type=float)
    p_record_final.add_argument("--final-tns", required=True, type=float)
    p_record_final.add_argument("--final-area", required=True, type=float)
    p_record_final.add_argument("--final-slew", required=True, type=float)
    p_record_final.set_defaults(func=cmd_record_final)

    p_finalize = sub.add_parser("finalize", help="compute winner and write winner artifact")
    p_finalize.add_argument("--state", required=True)
    p_finalize.add_argument("--winner-out", required=True)
    p_finalize.set_defaults(func=cmd_finalize)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
