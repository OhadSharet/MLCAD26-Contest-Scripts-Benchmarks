#!/usr/bin/env python3
"""Merge CSV files from two run folders into one interleaved comparison CSV.

For each matching CSV (same relative path under both run folders), rows are
interleaved by design:
  run1_designA
  run2_designA
  run1_designB
  run2_designB

All matching CSVs are appended into a single output file.
Only one extra column is added: the source run folder name.
"""

import argparse
import csv
from pathlib import Path
from typing import Dict, List, Set, Tuple


def find_csvs(root: Path) -> Set[Path]:
    """Return CSV paths as relative paths under root."""
    return {p.relative_to(root) for p in root.rglob("*.csv") if p.is_file()}


def read_csv_rows(path: Path) -> Tuple[List[str], List[Dict[str, str]]]:
    """Read CSV headers and rows."""
    with path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        headers = reader.fieldnames or []
        rows = list(reader)
    return headers, rows


def row_key(row: Dict[str, str], fallback_idx: int) -> str:
    """Prefer design as key, then benchmark/name/id, then stable row index."""
    for key in ("design", "benchmark", "name", "id"):
        value = (row.get(key) or "").strip()
        if value:
            return value
    return f"row_{fallback_idx:06d}"


def merge_pair_rows(
    rel_csv: Path,
    run1_label: str,
    run2_label: str,
    run1_rows: List[Dict[str, str]],
    run2_rows: List[Dict[str, str]],
) -> List[Dict[str, str]]:
    """Interleave rows from run1/run2 by key for one CSV path."""
    run1_map: Dict[str, Dict[str, str]] = {}
    run2_map: Dict[str, Dict[str, str]] = {}
    key_order: List[str] = []
    seen_keys: Set[str] = set()

    for idx, row in enumerate(run1_rows, start=1):
        key = row_key(row, idx)
        if key not in seen_keys:
            key_order.append(key)
            seen_keys.add(key)
        run1_map[key] = row

    for idx, row in enumerate(run2_rows, start=1):
        key = row_key(row, idx)
        if key not in seen_keys:
            key_order.append(key)
            seen_keys.add(key)
        run2_map[key] = row

    merged: List[Dict[str, str]] = []
    for key in key_order:
        if key in run1_map:
            out_row = dict(run1_map[key])
            out_row["source_run"] = run1_label
            merged.append(out_row)

        if key in run2_map:
            out_row = dict(run2_map[key])
            out_row["source_run"] = run2_label
            merged.append(out_row)

    return merged


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Merge all CSVs from two run folders into one interleaved comparison CSV."
    )
    parser.add_argument("run1", type=Path, help="First run folder")
    parser.add_argument("run2", type=Path, help="Second run folder")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("results/comparisons"),
        help="Output directory for merged CSV (default: results/comparisons)",
    )
    parser.add_argument(
        "--output-name",
        default="merged_comparison.csv",
        help="Output CSV file name (default: merged_comparison.csv)",
    )
    args = parser.parse_args()

    if not args.run1.is_dir():
        raise SystemExit(f"Error: not a directory: {args.run1}")
    if not args.run2.is_dir():
        raise SystemExit(f"Error: not a directory: {args.run2}")

    run1_label = args.run1.name
    run2_label = args.run2.name

    run1_csvs = find_csvs(args.run1)
    run2_csvs = find_csvs(args.run2)
    common_csvs = sorted(run1_csvs.intersection(run2_csvs))

    if not common_csvs:
        raise SystemExit("No matching CSV files found between the two folders.")

    all_rows: List[Dict[str, str]] = []
    all_fields: List[str] = []
    seen_fields: Set[str] = set()

    for rel_csv in common_csvs:
        run1_csv_path = args.run1 / rel_csv
        run2_csv_path = args.run2 / rel_csv

        _, run1_rows = read_csv_rows(run1_csv_path)
        _, run2_rows = read_csv_rows(run2_csv_path)

        merged_rows = merge_pair_rows(
            rel_csv=rel_csv,
            run1_label=run1_label,
            run2_label=run2_label,
            run1_rows=run1_rows,
            run2_rows=run2_rows,
        )

        for row in merged_rows:
            for key in row.keys():
                if key not in seen_fields:
                    seen_fields.add(key)
                    all_fields.append(key)
            all_rows.append(row)

    # Keep original fields, with source run folder prepended as first column.
    ordered_fields = ["source_run"]
    ordered_fields.extend([f for f in all_fields if f != "source_run"])

    args.output_dir.mkdir(parents=True, exist_ok=True)
    out_csv = args.output_dir / args.output_name

    with out_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=ordered_fields, extrasaction="ignore")
        writer.writeheader()
        for row in all_rows:
            writer.writerow(row)

    print(f"Wrote {len(all_rows)} rows from {len(common_csvs)} CSV files to: {out_csv}")


if __name__ == "__main__":
    main()