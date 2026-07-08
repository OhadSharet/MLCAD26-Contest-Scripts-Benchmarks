SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOP_PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PROJ_DIR="${TOP_PROJ_DIR}/evaluation"

export DESIGN_NAME=${1:?design name required}
export FOLDER_NAME="${2:-${DESIGN_NAME}_evaluation}"

mkdir -p "${FOLDER_NAME}"
export LOG_FILE="${FOLDER_NAME}/evaluation.log"
export METRICS_CSV="${FOLDER_NAME}/metrics.csv"
export CONGESTION_REPORT="${FOLDER_NAME}/congestion_report.rpt"

export RUN_TIMESTAMP_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export RUN_GIT_COMMIT="$(git -C "${TOP_PROJ_DIR}" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"

"${TOP_PROJ_DIR}/OpenROAD/build/bin/openroad" -exit "${PROJ_DIR}/evaluation.tcl" | tee "${LOG_FILE}"

# output metrics to csv
python3 "${PROJ_DIR}/parse_log.py" "${LOG_FILE}" --csv "${METRICS_CSV}" 
