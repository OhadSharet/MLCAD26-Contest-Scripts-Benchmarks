SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RL_CODE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export TOP_PROJ_DIR="$(cd "${RL_CODE_DIR}/.." && pwd)"
export PROJ_DIR="${SCRIPT_DIR}"
export CORE_SHARED_DIR="${RL_CODE_DIR}/core_shared"
RUNNER_TCL="${EVAL_TCL:-evaluation_baseline.tcl}"

export DESIGN_NAME=${1:?design name required}
export FOLDER_NAME="${2:-${DESIGN_NAME}_evaluation}"

# Optional CLI overrides:
#   arg3: space-separated arm ids (e.g. "8 9 10 11 12 13 14 15")
#   arg4: per-arm budget in seconds (e.g. 3)
CLI_ACTIVE_ARMS="${3:-}"
CLI_ARM_BUDGET_SEC="${4:-}"

mkdir -p "${FOLDER_NAME}"
export LOG_FILE="${FOLDER_NAME}/evaluation.log"
export METRICS_CSV="${FOLDER_NAME}/metrics.csv"
export CONGESTION_REPORT="${FOLDER_NAME}/congestion_report.rpt"

if [[ -n "${CLI_ACTIVE_ARMS}" ]]; then
	export OFFLINE_ACTIVE_ARMS="${CLI_ACTIVE_ARMS}"
else
	export OFFLINE_ACTIVE_ARMS="${OFFLINE_ACTIVE_ARMS:-8 9 10 11 12 13 14 15}"
fi

if [[ -n "${CLI_ARM_BUDGET_SEC}" ]]; then
	export OFFLINE_ARM_BUDGET_SEC="${CLI_ARM_BUDGET_SEC}"
else
	export OFFLINE_ARM_BUDGET_SEC="${OFFLINE_ARM_BUDGET_SEC:-3}"
fi

export RUN_TIMESTAMP="$(TZ="Asia/Jerusalem" date +"%Y-%m-%dT%H:%M")"
export RUN_GIT_COMMIT="$(git -C "${TOP_PROJ_DIR}" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
export RUN_START_EPOCH="$(date +%s)"

printf '[config] offline_active_arms=%s\n' "${OFFLINE_ACTIVE_ARMS}" | tee "${LOG_FILE}"
printf '[config] offline_arm_budget_sec=%s\n' "${OFFLINE_ARM_BUDGET_SEC}" | tee -a "${LOG_FILE}"

(
	cd "${PROJ_DIR}" &&
	"${TOP_PROJ_DIR}/OpenROAD/build/bin/openroad" -exit "${RUNNER_TCL}"
) | tee -a "${LOG_FILE}"

# output metrics to csv
python3 "${CORE_SHARED_DIR}/parse_log.py" "${LOG_FILE}" --csv "${METRICS_CSV}"

export RUN_END_EPOCH="$(date +%s)"
export RUN_DURATION_SEC="$((RUN_END_EPOCH - RUN_START_EPOCH))"
printf '[timing] total_runtime_sec=%s\n' "${RUN_DURATION_SEC}" | tee -a "${LOG_FILE}"
