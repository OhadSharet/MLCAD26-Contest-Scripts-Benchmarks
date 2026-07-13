#!/usr/bin/env python3
"""Simple explore-first multi-armed bandit policy.

Phase 1 (warmup): play each arm exactly once in order.
Phase 2 (exploit): repeatedly play the arm with best warmup reward.

State is persisted to JSON after every update so runs can recover after crashes.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from arm_catalog import ARM_NAMES
from json_state_utils import atomic_write_json, load_json


@dataclass
class State:
    version: int
    num_arms: int
    max_steps: int
    total_steps: int
    warmup_rewards: list[float | None]
    best_warmup_arm: int | None
    history: list[dict[str, Any]]

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "num_arms": self.num_arms,
            "max_steps": self.max_steps,
            "total_steps": self.total_steps,
            "warmup_rewards": self.warmup_rewards,
            "best_warmup_arm": self.best_warmup_arm,
            "history": self.history,
            "arm_names": ARM_NAMES,
        }

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "State":
        return State(
            version=int(data.get("version", 1)),
            num_arms=int(data["num_arms"]),
            max_steps=int(data["max_steps"]),
            total_steps=int(data.get("total_steps", 0)),
            warmup_rewards=list(data.get("warmup_rewards", [])),
            best_warmup_arm=data.get("best_warmup_arm"),
            history=list(data.get("history", [])),
        )


def load_state(path: Path) -> State:
    data = load_json(path)
    return State.from_dict(data)


def best_warmup_arm(warmup_rewards: list[float | None]) -> int:
    best_idx = 0
    best_val = float("-inf")
    for i, val in enumerate(warmup_rewards):
        score = float("-inf") if val is None else float(val)
        if score > best_val:
            best_val = score
            best_idx = i
    return best_idx


def cmd_init(args: argparse.Namespace) -> int:
    path = Path(args.state)
    state = State(
        version=1,
        num_arms=len(ARM_NAMES),
        max_steps=max(1, int(args.iterations)),
        total_steps=0,
        warmup_rewards=[None] * len(ARM_NAMES),
        best_warmup_arm=None,
        history=[],
    )
    atomic_write_json(path, state.to_dict())
    return 0


def cmd_select(args: argparse.Namespace) -> int:
    state = load_state(Path(args.state))

    if state.total_steps >= state.max_steps:
        print("-1")
        return 0

    if state.total_steps < state.num_arms:
        arm_id = state.total_steps
    else:
        if state.best_warmup_arm is None:
            state.best_warmup_arm = best_warmup_arm(state.warmup_rewards)
            atomic_write_json(Path(args.state), state.to_dict())
        arm_id = int(state.best_warmup_arm)

    print(str(arm_id))
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    path = Path(args.state)
    state = load_state(path)

    arm_id = int(args.arm_id)
    reward = float(args.reward)

    if arm_id < 0 or arm_id >= state.num_arms:
        raise ValueError(f"arm_id out of range: {arm_id}")
    if state.total_steps >= state.max_steps:
        return 0

    record = {
        "step": state.total_steps,
        "arm_id": arm_id,
        "arm_name": ARM_NAMES[arm_id],
        "reward": reward,
        "wns_before": float(args.wns_before),
        "wns_after": float(args.wns_after),
        "tns_before": float(args.tns_before),
        "tns_after": float(args.tns_after),
        "area_before": float(args.area_before),
        "area_after": float(args.area_after),
        "wns_pct": float(args.wns_pct),
        "tns_pct": float(args.tns_pct),
        "area_pct": float(args.area_pct),
        "legalization_used": int(args.legalization_used),
    }

    if state.total_steps < state.num_arms:
        state.warmup_rewards[arm_id] = reward

    state.history.append(record)
    state.total_steps += 1

    if state.total_steps >= state.num_arms:
        state.best_warmup_arm = best_warmup_arm(state.warmup_rewards)

    atomic_write_json(path, state.to_dict())
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Explore-first bandit policy")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="initialize state")
    p_init.add_argument("--state", required=True)
    p_init.add_argument("--iterations", required=True, type=int)
    p_init.set_defaults(func=cmd_init)

    p_select = sub.add_parser("select", help="select arm id")
    p_select.add_argument("--state", required=True)
    p_select.set_defaults(func=cmd_select)

    p_update = sub.add_parser("update", help="update state with reward")
    p_update.add_argument("--state", required=True)
    p_update.add_argument("--arm-id", required=True, type=int)
    p_update.add_argument("--reward", required=True, type=float)
    p_update.add_argument("--wns-before", required=True, type=float)
    p_update.add_argument("--wns-after", required=True, type=float)
    p_update.add_argument("--tns-before", required=True, type=float)
    p_update.add_argument("--tns-after", required=True, type=float)
    p_update.add_argument("--area-before", required=True, type=float)
    p_update.add_argument("--area-after", required=True, type=float)
    p_update.add_argument("--wns-pct", required=True, type=float)
    p_update.add_argument("--tns-pct", required=True, type=float)
    p_update.add_argument("--area-pct", required=True, type=float)
    p_update.add_argument("--legalization-used", required=True, type=int)
    p_update.set_defaults(func=cmd_update)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
