#!/bin/bash
set -euo pipefail

export DKMS_MODE="${DKMS_MODE:-false}"
TEST_MODES="oc,bc,dualnicbc,dualnicbcha,dualfollower"
RUN_PHASE="all"
REGISTRY_IP=""
TARBALL=""

while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dkms)    export DKMS_MODE=true; shift ;;
        --mode)    TEST_MODES="$2"; shift 2 ;;
        --images)  RUN_PHASE="images"; shift ;;
        --deploy)  RUN_PHASE="deploy"; REGISTRY_IP="$2"; shift 2 ;;
        --load)    RUN_PHASE="load"; TARBALL="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

VM_IP=$1

# Save full run output under /tmp/ptp-operator (timestamped file; also shown on the terminal).
mkdir -p /tmp/ptp-operator
RUN_ON_VM_LOG="/tmp/ptp-operator/run-on-vm-$(date +%Y%m%d-%H%M%S).log"

COLOR_STEP='\033[1;36m'
COLOR_ERR='\033[1;31m'
COLOR_OK='\033[1;32m'
COLOR_GRAY='\033[90m'
COLOR_RESET='\033[0m'

RUN_ON_VM_STEP_HDR="${COLOR_STEP}STEP:${COLOR_RESET}"
RUN_ON_VM_STEP_CHILD_INDENT='  '
RUN_ON_VM_PHASE_FAIL_PREFIX="${COLOR_ERR}FAIL "
RUN_ON_VM_PHASE_LOG_BEGIN_PREFIX="${COLOR_ERR}---- BEGIN "
RUN_ON_VM_PHASE_LOG_END_PREFIX="${COLOR_ERR}---- END "

log_ts() { date '+%m/%d/%y %H:%M:%S.%3N'; }

log_ind() { echo -e "${RUN_ON_VM_STEP_CHILD_INDENT}$*"; }

run_ind() {
  local _rc
  "$@" 2>&1 | sed "s/^/${RUN_ON_VM_STEP_CHILD_INDENT}/"
  _rc=${PIPESTATUS[0]}
  return "${_rc}"
}

step() { echo -e "${COLOR_STEP}STEP:${COLOR_RESET} $* ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"; }

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

run_step_rows_begin() {
  STEP_ROWS_LABELS=("$@")
  STEP_ROWS_COUNT=${#STEP_ROWS_LABELS[@]}
  STEP_ROWS_DONE=()
  STEP_ROWS_TTY_REDRAW=0
  STEP_ROWS_MAX_LABEL_LEN=0

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

run_step_row_done() {
  local completed_label="$1"
  STEP_ROWS_DONE["${completed_label}"]=1

  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
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
PS1="${PS1:-}" source ~/.bashrc

step "Tidying and vendoring Go dependencies"
run_step_rows_begin "go mod tidy" "go mod vendor"

run_quiet_with_log_dump_on_failure "go-mod-tidy" go mod tidy
run_step_row_done "go mod tidy"

run_quiet_with_log_dump_on_failure "go-mod-vendor" go mod vendor
run_step_row_done "go mod vendor"

run_step_rows_end

# Image tags: keep identical to ptp-tools/Makefile VALUES=...
_ptp_tool_images=(lptpd cep ptpop krp openvswitch prometheus ptpmg debug)

# ── Images phase (--images or default) ──────────────────────────────
if [[ "$RUN_PHASE" == "all" || "$RUN_PHASE" == "images" ]]; then

    step "Cleaning existing kind cluster and containers"
    run_ind kind delete cluster --name kind-netdevsim || true
    run_ind podman rm -f switch1 || true

    export IMG_PREFIX="$VM_IP/test"

    step "Cleaning all ptp-tools images"
    cd ../ptp-tools
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

    if [[ "$RUN_PHASE" == "images" ]]; then
        step "Saving images to tarball"
        SAVE_ARGS=()
        for t in "${_ptp_tool_images[@]}"; do SAVE_ARGS+=("$IMG_PREFIX:$t"); done
        podman save -m -o /tmp/ptp-images.tar "${SAVE_ARGS[@]}"
        log_ind "Images saved to /tmp/ptp-images.tar ($(du -h /tmp/ptp-images.tar | cut -f1))"
    fi

fi

# ── Load phase (--load) ─────────────────────────────────────────────
if [[ "$RUN_PHASE" == "load" ]]; then

    export IMG_PREFIX="$VM_IP/test"

    step "Loading images from tarball"
    run_ind podman load -i "$TARBALL"

    OLD_PREFIX=$(podman images --format '{{.Repository}}:{{.Tag}}' | grep ":${_ptp_tool_images[0]}$" | head -1 | sed "s/:${_ptp_tool_images[0]}$//")
    if [[ "$OLD_PREFIX" != "$IMG_PREFIX" ]]; then
        step "Re-tagging images for local registry"
        for t in "${_ptp_tool_images[@]}"; do
            podman tag "$OLD_PREFIX:$t" "$IMG_PREFIX:$t"
        done
    fi

    step "Building kustomize"
    cd ..
    run_quiet_with_log_dump_on_failure "make-kustomize" make kustomize
    cd -

    step "Creating local registry"
    run_quiet_with_log_dump_on_failure "create-local-registry" ./create-local-registry.sh "$VM_IP"

    step "Pushing images to local registry"
    for t in "${_ptp_tool_images[@]}"; do
        podman push "$IMG_PREFIX:$t" "docker://$IMG_PREFIX:$t" &
    done
    wait

fi

# ── Deploy phase (--deploy or default) ──────────────────────────────
if [[ "$RUN_PHASE" == "all" || "$RUN_PHASE" == "deploy" ]]; then

    if [[ "$RUN_PHASE" == "deploy" ]]; then
        export IMG_PREFIX="${REGISTRY_IP}/test"
    else
        export IMG_PREFIX="${IMG_PREFIX:-$VM_IP/test}"
    fi

    step "Cleaning existing kind cluster and containers"
    run_ind kind delete cluster --name kind-netdevsim || true
    run_ind podman rm -f switch1 || true

    step "Starting kind cluster"
    run_step_rows_begin "Building kind cluster..."
    run_quiet_with_log_dump_on_failure "k8s-start" ./k8s-start.sh "$VM_IP"
    run_step_row_done "Building kind cluster..."
    run_step_rows_end

    step "Deploying ptp-operator manifests"
    cd ../ptp-tools
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

    step "Patching ptpoperatorconfig for event publishing"
    run_quiet_with_log_dump_on_failure "retry-patch-ptpoperatorconfig" ./retry.sh 60 5 kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "local-sc"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'

    step "Waiting for linuxptp-daemon rollout"
    run_quiet_with_log_dump_on_failure "retry-rollout-status" ./retry.sh 30 3 kubectl rollout status ds linuxptp-daemon -n openshift-ptp

    step "Fixing Prometheus monitoring"
    run_quiet_with_log_dump_on_failure "fix-ptp-prometheus-monitoring" ./fix-ptp-prometheus-monitoring.sh

    step "Listing openshift-ptp pods"
    run_ind kubectl get pods -n openshift-ptp -o wide

    SYMLINK_PID=""
    if [[ "${DKMS_MODE}" == "true" ]]; then
        bash -c '
        while true; do
          for pod in $(kubectl get pods -n openshift-ptp -l app=linuxptp-daemon \
                       --field-selector=status.phase=Running -o name 2>/dev/null); do
            kubectl exec -n openshift-ptp ${pod#pod/} -c linuxptp-daemon-container -- \
              bash -c "for i in 0 1 2 3 4 5 6 7 8 9; do ln -sf nsim_ptp\$i /dev/ptp\$i 2>/dev/null; done" \
              2>/dev/null || true
          done
          sleep 5
        done
        ' &
        SYMLINK_PID=$!
        log_ind "Symlink maintainer PID: $SYMLINK_PID"
        cleanup_symlink() { [[ -n "$SYMLINK_PID" ]] && kill "$SYMLINK_PID" 2>/dev/null || true; }
        trap cleanup_symlink EXIT
    fi

    ./run-tests.sh --kind serial --mode "$TEST_MODES" \
      --linuxptp-daemon-image "$IMG_PREFIX:lptpd" \
      --must-gather-image "$IMG_PREFIX:ptpmg" \
      --debug-image "$IMG_PREFIX:debug"

fi
