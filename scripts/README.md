# MLCAD 2026 Evaluation

> Adapted from the official scripts of the [ISPD 2026 Contest](https://github.com/ABKGroup/ISPD26-Contest) by [ABKGroup @ UC San Diego](https://github.com/ABKGroup).

---

## Repository Structure

```
.
├── Benchmarks/
│   └── {design}/
│       ├── pre_opt/
│       │   └── {folder}/
│       │       ├── node.csv
│       │       └── nets.csv
│       └── post_opt/
│           └── {folder}/
│               ├── node.csv
│               └── nets.csv
│
└── scripts/
    ├── {design}/
    │   ├── eval.sh
    │   ├── design_setup.tcl
    │   ├── lib_setup.tcl
    │   └── {folder}/
    │     ├── evaluation.log
    │     ├── metrics.csv
    ├── evaluation.tcl
    ├── parse_log.py
    └── compute_score.py
    
```

---

## Usage

### Step 1 — Update design files

Point `$def_file` and `$verilog_netlist` in `scripts/{design}/design_setup.tcl` to your optimized outputs.

### Step 2 — Run evaluation

```bash
cd scripts/{design}
source eval.sh
```

Or manually:

```bash
export TOP_PROJ_DIR="/path/to/repo"
export PROJ_DIR="${TOP_PROJ_DIR}/scripts"
export DESIGN_NAME="jpeg_encoder"
export FOLDER_NAME="TCP_350_UTIL_0.70"

mkdir -p ${FOLDER_NAME}

/OpenROAD/build/bin/openroad -exit ${PROJ_DIR}/evaluation.tcl \
  | tee ${FOLDER_NAME}/evaluation.log

python3 ${PROJ_DIR}/parse_log.py ${FOLDER_NAME}/evaluation.log \
  --csv ${FOLDER_NAME}/metrics.csv
```

Outputs written to `scripts/{design}/{folder_name}/`: `evaluation.log`, `metrics.csv`, `congestion_report.rpt`.

### Step 3 — Compute score

```bash
python3 scripts/compute_score.py \
    --design_name jpeg_encoder \
    --contest_post_dir Benchmarks/jpeg_encoder/post_opt/TCP_350_UTIL_0.70
```

Score formula: `Sfinal = SPPA − PERC − R − Pdis − Poverflow`

| Term | Description |
|------|-------------|
| `SPPA` | TNS + dynamic power + leakage power improvement |
| `PERC` | Slew, capacitance, fanout violation penalty |
| `R` | Runtime penalty (tool + flow) |
| `Pdis` | Average logic cell displacement penalty |
| `Poverflow` | Global routing overflow penalty |

---