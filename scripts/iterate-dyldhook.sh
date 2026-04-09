#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_NAME="$(basename "$0")"

DOPAMINE_ROOT="/Users/rachel/Codelab/Dopamine"
SSH_TARGET="iproxy"
SSH_HOST=""
SSH_PORT=""
SSH_USER=""
REMOTE_DIR="/rootfs/var/mobile/Documents"
REMOTE_TAR_NAME="basebin-dyldhook-update.tar"
OUTPUT_DIR="${ROOT_DIR}/.build"
SKIP_BUILD=0
SKIP_DEPLOY=0
SKIP_LOGS=0
TAIL_SECONDS=180
WAIT_SECONDS=180
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
STEP_INDEX=0
TOTAL_STEPS=0

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
else
    C_RESET=""
    C_BOLD=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
fi

log_step() {
    STEP_INDEX=$((STEP_INDEX + 1))
    printf "%s%s[%d/%d]%s %s\n" "${C_BOLD}" "${C_CYAN}" "${STEP_INDEX}" "${TOTAL_STEPS}" "${C_RESET}" "$1"
}

log_info() {
    printf "%sInfo:%s %s\n" "${C_CYAN}" "${C_RESET}" "$1"
}

log_warn() {
    printf "%sWarning:%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1" >&2
}

log_error() {
    printf "%sError:%s %s\n" "${C_RED}" "${C_RESET}" "$1" >&2
}

log_success() {
    printf "%s%s%s\n" "${C_GREEN}" "$1" "${C_RESET}"
}

pick_tar_bin() {
    if command -v gtar >/dev/null 2>&1; then
        print -- "gtar"
        return
    fi
    print -- "tar"
}

create_root_owned_tar() {
    local tar_path="$1"
    local source_dir="$2"
    local source_entry="$3"

    if [[ "${TAR_BIN}" == "gtar" ]]; then
        "${TAR_BIN}" --owner=0 --group=0 --numeric-owner -cf "${tar_path}" -C "${source_dir}" "${source_entry}"
    else
        "${TAR_BIN}" --uid 0 --gid 0 --numeric-owner -cf "${tar_path}" -C "${source_dir}" "${source_entry}"
    fi
}

verify_tar_root_owned() {
    local tar_path="$1"
    local verify_log="$2"

    typeset -a verify_cmd=()
    if command -v bsdtar >/dev/null 2>&1; then
        verify_cmd=(bsdtar --numeric-owner -tvf "${tar_path}")
    else
        verify_cmd=("${TAR_BIN}" --numeric-owner -tvf "${tar_path}")
    fi

    if "${verify_cmd[@]}" | awk '
        {
            owner = $3
            group = $4
            if (owner ~ /^[0-9]+\/[0-9]+$/) {
                split(owner, pair, "/")
                owner = pair[1]
                group = pair[2]
            }
            if (owner != "0" || group != "0") {
                print
                bad = 1
            }
        }
        END { exit bad }
    ' > "${verify_log}"; then
        return 0
    fi

    log_error "Package contains non-root ownership entries. First mismatches:"
    sed -n '1,20p' "${verify_log}" >&2 || true
    return 1
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --dopamine-root <path>     Dopamine repository path (default: ${DOPAMINE_ROOT})
  --ssh-target <host>        SSH config host alias (default: ${SSH_TARGET})
  --ssh-host <host>          Direct SSH host (overrides --ssh-target)
  --ssh-port <port>          SSH port (used with --ssh-host or --ssh-target)
  --ssh-user <user>          SSH user
  --remote-dir <path>        Device temp dir for update package (default: ${REMOTE_DIR})
  --remote-tar-name <name>   Device tar filename (default: ${REMOTE_TAR_NAME})
  --output-dir <path>        Local output dir for package/logs (default: ${OUTPUT_DIR})
  --jobs <n>                 Build parallelism for dyldhook make (default: ${JOBS})
  --tail-seconds <n>         log show window after reboot (default: ${TAIL_SECONDS})
  --wait-seconds <n>         Max wait for SSH reconnect (default: ${WAIT_SECONDS})
  --skip-build               Do not build dyldhook; use existing binaries
  --skip-deploy              Build/package only; do not upload/update device
  --skip-logs                Do not collect post-reboot logs
  -h, --help                 Show this help

What it does:
  1) Build Dopamine BaseBin/dyldhook only
  2) Build a safe basebin update tar:
     - default: pull current full /basebin from device, then overlay new dyldhook dylibs
     - when --skip-deploy: local minimal tar (for offline inspection only)
  3) Upload tar to device and run: /basebin/jbctl update basebin <tar>
  4) Wait for SSH reconnect (userspace reboot)
  5) Collect one compact device log snapshot
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dopamine-root)
            DOPAMINE_ROOT="${2:?missing value for --dopamine-root}"
            shift 2
            ;;
        --ssh-target)
            SSH_TARGET="${2:?missing value for --ssh-target}"
            shift 2
            ;;
        --ssh-host)
            SSH_HOST="${2:?missing value for --ssh-host}"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="${2:?missing value for --ssh-port}"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="${2:?missing value for --ssh-user}"
            shift 2
            ;;
        --remote-dir)
            REMOTE_DIR="${2:?missing value for --remote-dir}"
            shift 2
            ;;
        --remote-tar-name)
            REMOTE_TAR_NAME="${2:?missing value for --remote-tar-name}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:?missing value for --output-dir}"
            shift 2
            ;;
        --jobs)
            JOBS="${2:?missing value for --jobs}"
            shift 2
            ;;
        --tail-seconds)
            TAIL_SECONDS="${2:?missing value for --tail-seconds}"
            shift 2
            ;;
        --wait-seconds)
            WAIT_SECONDS="${2:?missing value for --wait-seconds}"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --skip-deploy)
            SKIP_DEPLOY=1
            shift
            ;;
        --skip-logs)
            SKIP_LOGS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage >&2
            exit 1
            ;;
    esac
done

BASEBIN_DIR="${DOPAMINE_ROOT}/BaseBin"
DYLDHOOK_DIR="${BASEBIN_DIR}/dyldhook"
BASEBIN_TC="${BASEBIN_DIR}/basebin.tc"
BASEBIN_VERSION="${BASEBIN_DIR}/_external/basebin/.version"
BASEBIN_INCLUDE_DIR="${BASEBIN_DIR}/.include"
BASEBIN_EXT_INCLUDE_DIR="${BASEBIN_DIR}/_external/include"
BASEBIN_XPC_INCLUDE_DIR="${BASEBIN_INCLUDE_DIR}/xpc"
BASEBIN_XPC_EXT_INCLUDE_DIR="${BASEBIN_EXT_INCLUDE_DIR}/xpc"

for required_dir in "${DOPAMINE_ROOT}" "${BASEBIN_DIR}" "${DYLDHOOK_DIR}"; do
    if [[ ! -d "${required_dir}" ]]; then
        log_error "Required path does not exist: ${required_dir}"
        exit 1
    fi
done

if [[ ! -d "${BASEBIN_INCLUDE_DIR}" ]]; then
    log_warn "BaseBin include dir missing; regenerating it via make .include..."
    make -C "${BASEBIN_DIR}" .include
fi

if [[ ! -d "${BASEBIN_XPC_INCLUDE_DIR}" ]]; then
    if [[ -d "${BASEBIN_XPC_EXT_INCLUDE_DIR}" ]]; then
        log_info "Restoring missing BaseBin xpc headers from _external/include/xpc..."
        cp -R "${BASEBIN_XPC_EXT_INCLUDE_DIR}" "${BASEBIN_XPC_INCLUDE_DIR}"
    else
        log_error "Missing xpc headers in both ${BASEBIN_XPC_INCLUDE_DIR} and ${BASEBIN_XPC_EXT_INCLUDE_DIR}"
        exit 1
    fi
fi

if [[ ! -f "${BASEBIN_TC}" ]]; then
    log_error "Missing file: ${BASEBIN_TC}"
    log_info "Build BaseBin once first (e.g. make -C ${BASEBIN_DIR} basebin.tc)."
    exit 1
fi

if [[ ! -f "${BASEBIN_VERSION}" ]]; then
    log_error "Missing file: ${BASEBIN_VERSION}"
    exit 1
fi

typeset -a ssh_extra_args=()
if [[ -n "${SSH_PORT}" ]]; then
    ssh_extra_args+=("-p" "${SSH_PORT}")
fi

if [[ -n "${SSH_HOST}" ]]; then
    remote="${SSH_HOST}"
    if [[ -n "${SSH_USER}" ]]; then
        remote="${SSH_USER}@${SSH_HOST}"
    fi
else
    remote="${SSH_TARGET}"
fi

mkdir -p "${OUTPUT_DIR}"
timestamp="$(date +%Y%m%d-%H%M%S)"
PACKAGE_PATH="${OUTPUT_DIR}/basebin-dyldhook-${timestamp}.tar"
LOG_PATH="${OUTPUT_DIR}/dyldhook-iterate-${timestamp}.log"

TAR_BIN="$(pick_tar_bin)"
if [[ "${TAR_BIN}" == "gtar" ]]; then
    log_info "Using GNU tar for packaging: ${TAR_BIN}"
else
    log_warn "gtar not found; falling back to tar. Packaging remains supported but less deterministic."
fi

typeset -a dylib_names=(
    "dyldhook_merge.arm64.dylib"
    "dyldhook_merge.arm64e.dylib"
    "dyldhook_merge.arm64.iOS15.dylib"
    "dyldhook_merge.arm64e.iOS15.dylib"
)

TOTAL_STEPS=1
[[ "${SKIP_BUILD}" != "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "${SKIP_DEPLOY}" != "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
if [[ "${SKIP_DEPLOY}" != "1" && "${SKIP_LOGS}" != "1" ]]; then
    TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi

if [[ "${SKIP_BUILD}" != "1" ]]; then
    log_step "Building dyldhook only..."
    make -C "${DYLDHOOK_DIR}" -j"${JOBS}"
fi

log_step "Assembling basebin update package..."
WORK_DIR="$(mktemp -d "${OUTPUT_DIR}/.dyldhook-iterate.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${WORK_DIR}/basebin"
if [[ "${SKIP_DEPLOY}" == "1" ]]; then
    log_warn "Using local minimal basebin package because --skip-deploy is set."
    cp "${BASEBIN_TC}" "${WORK_DIR}/basebin/basebin.tc"
    cp "${BASEBIN_VERSION}" "${WORK_DIR}/basebin/.version"
else
    log_info "Snapshotting current /basebin from device (excluding .fakelib/.jbroot/log) to preserve trustcache coverage..."
    REMOTE_SNAPSHOT_TAR="${WORK_DIR}/remote-basebin-snapshot.tar"
    ssh "${ssh_extra_args[@]}" "${remote}" \
        "if command -v gtar >/dev/null 2>&1; then T=gtar; else T=/usr/bin/tar; fi; \"\$T\" -cf - --exclude '.fakelib' --exclude '.jbroot' --exclude 'roothide-spawn.log' -C /basebin ." \
        > "${REMOTE_SNAPSHOT_TAR}"
    "${TAR_BIN}" -xf "${REMOTE_SNAPSHOT_TAR}" -C "${WORK_DIR}/basebin"
fi

for dylib_name in "${dylib_names[@]}"; do
    dylib_path="${DYLDHOOK_DIR}/${dylib_name}"
    if [[ ! -f "${dylib_path}" ]]; then
        log_error "Missing dyldhook artifact: ${dylib_path}"
        exit 1
    fi
    cp "${dylib_path}" "${WORK_DIR}/basebin/${dylib_name}"
done

if [[ ! -f "${WORK_DIR}/basebin/basebin.tc" ]]; then
    cp "${BASEBIN_TC}" "${WORK_DIR}/basebin/basebin.tc"
fi
if [[ ! -f "${WORK_DIR}/basebin/.version" ]]; then
    cp "${BASEBIN_VERSION}" "${WORK_DIR}/basebin/.version"
fi

create_root_owned_tar "${PACKAGE_PATH}" "${WORK_DIR}" "basebin"
VERIFY_LOG="${WORK_DIR}/ownership-check.txt"
verify_tar_root_owned "${PACKAGE_PATH}" "${VERIFY_LOG}"
log_success "Package created: ${PACKAGE_PATH}"

if [[ "${SKIP_DEPLOY}" == "1" ]]; then
    log_info "Skipping device deploy as requested."
    exit 0
fi

remote_tar="${REMOTE_DIR%/}/${REMOTE_TAR_NAME}"
jbctl_tar="${remote_tar}"
if [[ "${jbctl_tar}" == /rootfs/* ]]; then
    jbctl_tar="${jbctl_tar#/rootfs}"
fi

log_step "Uploading package and staging jbctl basebin update..."
ssh "${ssh_extra_args[@]}" "${remote}" "mkdir -p '${REMOTE_DIR}'"
scp "${ssh_extra_args[@]}" "${PACKAGE_PATH}" "${remote}:${remote_tar}"

set +e
ssh "${ssh_extra_args[@]}" "${remote}" "/basebin/jbctl update basebin '${jbctl_tar}'"
update_rc=$?
set -e
if [[ "${update_rc}" -ne 0 && "${update_rc}" -ne 255 ]]; then
    log_error "jbctl update failed with exit code ${update_rc}."
    exit "${update_rc}"
fi
if [[ "${update_rc}" -ne 0 ]]; then
    log_warn "jbctl returned non-zero (${update_rc}). This can happen if SSH drops during userspace reboot."
fi

log_step "Waiting for device SSH to come back (<= ${WAIT_SECONDS}s)..."
start_ts="$(date +%s)"
while true; do
    if ssh "${ssh_extra_args[@]}" -o ConnectTimeout=3 "${remote}" "echo up" >/dev/null 2>&1; then
        break
    fi
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= WAIT_SECONDS )); then
        log_error "Timed out waiting for device reconnect."
        exit 1
    fi
    sleep 2
done

if [[ "${SKIP_LOGS}" == "1" ]]; then
    log_success "Device reconnected. Done."
    exit 0
fi

log_step "Collecting post-reboot runtime logs..."
ssh "${ssh_extra_args[@]}" "${remote}" \
    "echo '==== roothide-spawn.log (tail) ===='; \
     tail -n 400 /basebin/roothide-spawn.log 2>/dev/null || echo '(missing)'; \
     echo; \
     echo '==== CrashReporter candidates ===='; \
     for d in /rootfs/var/mobile/Library/Logs/CrashReporter /var/mobile/Library/Logs/CrashReporter; do \
         if [ -d \"\$d\" ]; then \
             echo \"[dir] \$d\"; \
             ls -1t \"\$d\" 2>/dev/null | head -n 30; \
         fi; \
     done" \
    > "${LOG_PATH}" || true

log_success "Iteration done."
log_info "Package: ${PACKAGE_PATH}"
log_info "Log: ${LOG_PATH}"
