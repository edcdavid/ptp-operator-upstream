#!/bin/bash
set -euo pipefail

# Save full run output under /tmp/ptp-operator (timestamped file; also shown on the terminal).
mkdir -p /tmp/ptp-operator
RUN_ON_VM_LOG="/tmp/ptp-operator/run-on-vm-$(date +%Y%m%d-%H%M%S).log"

VM_IP=$1

COLOR_STEP='\033[1;36m'
COLOR_ERR='\033[1;31m'
COLOR_OK='\033[1;32m'
COLOR_GRAY='\033[90m'
COLOR_RESET='\033[0m'

RUN_ON_VM_STEP_HDR="${COLOR_STEP}STEP:${COLOR_RESET}"
RUN_ON_VM_STEP_CHILD_INDENT='  '
# run_quiet_with_log_dump_on_failure only prints on failure
RUN_ON_VM_PHASE_FAIL_PREFIX="${COLOR_ERR}FAIL "
RUN_ON_VM_PHASE_LOG_BEGIN_PREFIX="${COLOR_ERR}---- BEGIN "
RUN_ON_VM_PHASE_LOG_END_PREFIX="${COLOR_ERR}---- END "

# Same clock layout as Ginkgo's default GINKGO_TIME_FORMAT ("01/02/06 15:04:05.999", see onsi/ginkgo/v2/types).
log_ts() { date '+%m/%d/%y %H:%M:%S.%3N'; }

# Echo with indent only.
log_ind() { echo -e "${RUN_ON_VM_STEP_CHILD_INDENT}$*"; }

# Log the command, run it, print stdout/stderr with indent on each line.
run_ind() {
  local _rc
  "$@" 2>&1 | sed "s/^/${RUN_ON_VM_STEP_CHILD_INDENT}/"
  _rc=${PIPESTATUS[0]}
  return "${_rc}"
}

step() { echo -e "${COLOR_STEP}STEP:${COLOR_RESET} $* ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"; }

# Run with stdout/stderr captured; no output on success, On failure, print the command log.
run_quiet_with_log_dump_on_failure() {
  local log_tag="$1"
  shift

  local log_file
  log_file="$(mktemp "/tmp/ptp-operator/${log_tag// /_}.XXXXXX.log")"

  local rc
  if command -v setsid >/dev/null 2>&1; then
    if setsid "$@" >"${log_file}" 2>&1 </dev/null; then
      rc=0
    else
      rc=$?
    fi
  else
    if "$@" >"${log_file}" 2>&1 </dev/null; then
      rc=0
    else
      rc=$?
    fi
  fi

  if [[ "${rc}" -eq 0 ]]; then
    rm -f "${log_file}"
    return 0
  fi

  echo -e "${COLOR_ERR}FAIL ${log_tag}:${COLOR_RESET} (exit code ${rc}) ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
  echo -e "${COLOR_ERR}---- BEGIN ${log_tag} LOG ----${COLOR_RESET} ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
  cat "${log_file}"
  echo -e "${COLOR_ERR}---- END ${log_tag} LOG ----${COLOR_RESET} ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
  rm -f "${log_file}"
  return "${rc}"
}

declare -A STEP_ROWS_DONE

# Print the initial "LABELS <image>" list
run_step_rows_begin() {
  STEP_ROWS_LABELS=("$@")
  STEP_ROWS_COUNT=${#STEP_ROWS_LABELS[@]}
  STEP_ROWS_DONE=()
  STEP_ROWS_TTY_REDRAW=0
  STEP_ROWS_MAX_LABEL_LEN=0

  # stdout is piped through awk|tee in this script; if /dev/tty is writable,
  # use it for in-place redraw regardless of stdio redirection.
  if [[ -w /dev/tty ]]; then
    exec 9>/dev/tty
    STEP_ROWS_TTY_REDRAW=1
  fi

  for _line in "${STEP_ROWS_LABELS[@]}"; do
    [[ ${#_line} -gt $STEP_ROWS_MAX_LABEL_LEN ]] && STEP_ROWS_MAX_LABEL_LEN=${#_line}
  done

  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
    for _line in "${STEP_ROWS_LABELS[@]}"; do
      printf '  %-*s\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}" >&9
    done
  else
    for _line in "${STEP_ROWS_LABELS[@]}"; do
      printf '  %-*s\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}"
    done
  fi
}

# Marks a row as done if the command completed, otherwise print the row.
run_step_row_done() {
  local completed_label="$1"
  STEP_ROWS_DONE["${completed_label}"]=1

  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
    # Cursor is on the line after the block; move up to the first row of this block.
    printf '\033[%dA' "${STEP_ROWS_COUNT}" >&9
    local _line
    for _line in "${STEP_ROWS_LABELS[@]}"; do
      printf '\033[2K\r' >&9
      if [[ "${STEP_ROWS_DONE["${_line}"]:-0}" == 1 ]]; then
        printf '  %-*s %bOK%b\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}" "${COLOR_OK}" "${COLOR_RESET}" >&9
      else
        printf '  %-*s\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}" >&9
      fi
    done

  else
    printf '  %-*s %bOK%b %b@ %s%b\n' \
      "${STEP_ROWS_MAX_LABEL_LEN}" "${completed_label}" \
      "${COLOR_OK}" "${COLOR_RESET}" \
      "${COLOR_GRAY}" "$(log_ts)" "${COLOR_RESET}"
  fi
}

run_step_rows_end() {
  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
    exec 9>&-
    STEP_ROWS_TTY_REDRAW=0
  fi
}

# Parallel `make -s podman-<verb>-<img>` for each image tag, with the same step-row UI as sequential work:
# print "<row_prefix> <img>" lines, run all makes concurrently, mark each row OK on completion.
run_ptp_tools_parallel_make_step_rows() {
  local row_prefix="$1"
  local make_prefix="$2"
  local fifo_tag="$3"
  shift 3
  local -a images=("$@")
  local n=${#images[@]}

  local -a rows=()
  local _img
  for _img in "${images[@]}"; do
    rows+=("${row_prefix} ${_img}")
  done
  run_step_rows_begin "${rows[@]}"

  local fifo="/tmp/ptp-operator/ptp-${fifo_tag}-done-$$.fifo"
  rm -f "${fifo}"
  mkfifo "${fifo}"
  exec 8<> "${fifo}"

  local -a pids=()
  local _i
  for _i in "${!images[@]}"; do
    (
      _img="${images[$_i]}"
      if run_quiet_with_log_dump_on_failure "${make_prefix}-${_img}" make -s "${make_prefix}-${_img}"; then
        echo "${_img}" >&8
      else
        echo "FAIL:${_img}" >&8
      fi
    ) &
    pids+=($!)
  done

  local done_count=0
  local failed=0
  local line
  while ((done_count < n)); do
    IFS= read -r line <&8 || {
      failed=1
      break
    }
    if [[ "${line}" == FAIL:* ]]; then
      failed=1
      break
    fi
    ((done_count++)) || true
    run_step_row_done "${row_prefix} ${line}"
  done

  if ((failed)); then
    local _pid
    for _pid in "${pids[@]}"; do
      kill "${_pid}" 2>/dev/null || true
    done
    for _pid in "${pids[@]}"; do
      wait "${_pid}" 2>/dev/null || true
    done
    exec 8>&-
    rm -f "${fifo}"
    run_step_rows_end
    exit 1
  fi

  local _pid
  for _pid in "${pids[@]}"; do
    wait "${_pid}"
  done
  exec 8>&-
  rm -f "${fifo}"
  run_step_rows_end
}

step "Switching to script directory"
cd "$(dirname "${BASH_SOURCE[0]}")"

log_ind "Now in: $(pwd) ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"

export GOMAXPROCS=$(nproc)

step "Installing required tools"
run_quiet_with_log_dump_on_failure "install-tools" bash ./install-tools.sh

export BASHRCSOURCED=1
source ~/.bashrc

step "Tidying and vendoring Go dependencies"
run_step_rows_begin "go mod tidy" "go mod vendor"

run_quiet_with_log_dump_on_failure "go-mod-tidy" go mod tidy
run_step_row_done "go mod tidy"

run_quiet_with_log_dump_on_failure "go-mod-vendor" go mod vendor
run_step_row_done "go mod vendor"

run_step_rows_end

step "Cleaning existing kind cluster and containers"
run_ind kind delete cluster --name kind-netdevsim || true
run_ind podman rm -f switch1 || true

step "Cleaning all ptp-tools images"
cd ../ptp-tools
# configure images for local registry
export IMG_PREFIX="$VM_IP/test"
# Image tags: keep identical to ptp-tools/Makefile VALUES=...
_ptp_tool_images=(lptpd cep ptpop krp openvswitch prometheus ptpmg debug)
run_ptp_tools_parallel_make_step_rows CLEAN podman-clean clean "${_ptp_tool_images[@]}"

step "Building ptp-tools images"
run_ptp_tools_parallel_make_step_rows BUILD podman-build build "${_ptp_tool_images[@]}"

cd -

step "Building kustomize"
cd ..
run_quiet_with_log_dump_on_failure "make-kustomize" make kustomize
cd -

step "Creating local registry"
run_quiet_with_log_dump_on_failure "create-local-registry" ./create-local-registry.sh "$VM_IP"

step "Pushing images to local registry"
cd ../ptp-tools
run_ptp_tools_parallel_make_step_rows PUSH podman-push push "${_ptp_tool_images[@]}"
cd -

step "Starting kind cluster"
run_step_rows_begin "Building kind cluster..."
run_quiet_with_log_dump_on_failure "k8s-start" ./k8s-start.sh "$VM_IP"
run_step_row_done "Building kind cluster..."
run_step_rows_end

step "Deploying ptp-operator manifests"
cd ../ptp-tools
# Start deployment, it will fail because it is missing certs
run_step_rows_begin "make-deploy-all"
run_quiet_with_log_dump_on_failure "make-deploy-all" make deploy-all || true
run_step_row_done "make-deploy-all"
run_step_rows_end
sleep 5
cd -

step "Applying certificate manifests"
run_quiet_with_log_dump_on_failure "kubectl-apply-certs" kubectl apply -f certs.yaml

step "Fixing certificates"
run_quiet_with_log_dump_on_failure "retry-fix-certs" ./retry.sh 60 5 ./fix-certs.sh
sleep 5

step "Restarting ptp-operator pod"
run_quiet_with_log_dump_on_failure "kubectl-delete-pods" kubectl delete pods -l name=ptp-operator -n openshift-ptp

step "Waiting for ptp-operator rollout"
run_quiet_with_log_dump_on_failure "kubectl-rollout-status" kubectl rollout status deployment ptp-operator -n openshift-ptp

# Patch ptpoperatorconfig to start events (in case it is not configured yet )
step "Patching ptpoperatorconfig for event publishing"
run_quiet_with_log_dump_on_failure "retry-patch-ptpoperatorconfig" ./retry.sh 60 5 kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "local-sc"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'

step "Waiting for linuxptp-daemon rollout"
run_quiet_with_log_dump_on_failure "retry-rollout-status" ./retry.sh 30 3 kubectl rollout status ds linuxptp-daemon -n openshift-ptp

step "Fixing Prometheus monitoring"
run_quiet_with_log_dump_on_failure "fix-ptp-prometheus-monitoring" ./fix-ptp-prometheus-monitoring.sh

step "Listing openshift-ptp pods"
run_ind kubectl get pods -n openshift-ptp -o wide

# run tests
./run-tests.sh --kind serial --mode oc,bc,dualnicbc,dualnicbcha,dualfollower --linuxptp-daemon-image "$VM_IP/test:lptpd"
