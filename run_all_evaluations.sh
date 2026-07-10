#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_PROJ_DIR="${SCRIPT_DIR}"
EVAL_DIR="${TOP_PROJ_DIR}/evaluation"
RESULTS_ROOT="${1:-${TOP_PROJ_DIR}/results}"
RUN_LABEL="${2:-manual}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="${RUN_ID}_${RUN_LABEL}"
RUN_DIR="${RESULTS_ROOT}/${RUN_ID}"

mkdir -p "${RUN_DIR}"

SUMMARY_CSV="${RUN_DIR}/summary.csv"
RUN_MANIFEST_JSON="${RUN_DIR}/run_manifest.json"

cat > "${SUMMARY_CSV}" <<'EOF'
design,status,result_dir,metrics_csv,log_file
EOF

GIT_COMMIT="$(git -C "${TOP_PROJ_DIR}" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

BENCHMARKS=()
while IFS= read -r -d '' bench_dir; do
  bench_name="$(basename "${bench_dir}")"
  if [[ -f "${TOP_PROJ_DIR}/benchmarks/${bench_name}/${bench_name}.sdc" ]]; then
    BENCHMARKS+=("${bench_name}")
  fi
done < <(find "${TOP_PROJ_DIR}/benchmarks" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#BENCHMARKS[@]} -eq 0 ]]; then
  echo "No benchmarks found under ${TOP_PROJ_DIR}/benchmarks" >&2
  exit 1
fi

for design in "${BENCHMARKS[@]}"; do
  design_dir="${RUN_DIR}/${design}"
  mkdir -p "${design_dir}"

  status="ok"
  if (cd "${EVAL_DIR}" && source ./eval.sh "${design}" "${design_dir}"); then
    status="ok"
  else
    status="failed"
  fi

  metrics_csv="${design_dir}/metrics.csv"
  log_file="${design_dir}/evaluation.log"
  printf '%s,%s,%s,%s,%s\n' "${design}" "${status}" "${design_dir}" "${metrics_csv}" "${log_file}" >> "${SUMMARY_CSV}"
done

cat > "${RUN_MANIFEST_JSON}" <<EOF
{
  "run_id": "${RUN_ID}",
  "run_label": "${RUN_LABEL}",
  "run_dir": "${RUN_DIR}",
  "git_commit": "${GIT_COMMIT}",
  "timestamp": "$(TZ="Asia/Jerusalem" date +"%Y-%m-%dT%H:%M")",
  "benchmarks": [
$(for idx in "${!BENCHMARKS[@]}"; do
    if [[ ${idx} -lt $((${#BENCHMARKS[@]} - 1)) ]]; then
      printf '    "%s",\n' "${BENCHMARKS[$idx]}"
    else
      printf '    "%s"\n' "${BENCHMARKS[$idx]}"
    fi
  done)
  ]
}
EOF

echo "Run complete"
echo "  run_dir: ${RUN_DIR}"
echo "  summary : ${SUMMARY_CSV}"