#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1] == [$2]: $3"; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/etc/vless-reality"
export SONGBOX_SB_BIN="$TEST_ROOT/usr/local/bin/sing-box"
export SONGBOX_SB_SERVICE_FILE="$TEST_ROOT/etc/init.d/vless-singbox"
mkdir -p "$(dirname "$SONGBOX_SB_BIN")" "$(dirname "$SONGBOX_SB_SERVICE_FILE")" "$SONGBOX_CFG_DIR"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"
export DISTRO=alpine

_log() { :; }
make_fake_bin() {
    local path="$1" version="$2"
    printf '#!/usr/bin/env bash\nprintf "sing-box version %s\\n"\n' "$version" >"$path"
    chmod +x "$path"
}
seed_old_install() {
    make_fake_bin "$SONGBOX_SB_BIN" 1.13.12
    printf 'old-config\n' >"$SB_CONFIG"
    printf 'old-service\n' >"$SONGBOX_SB_SERVICE_FILE"
    SERVICE_RUNNING=true
}

TARGET_VERSION=1.14.0
HEALTH_MODE=success
STOP_ALLOWED=true
_resolve_singbox_version() { echo "${1:-$TARGET_VERSION}"; }
_download_singbox_binary() { make_fake_bin "$2" "$1"; }
get_singbox_protocols() { echo socks; }
generate_singbox_config() { printf '{"inbounds":[]}\n' >"$1"; }
create_singbox_service() { printf 'new-service\n' >"$SONGBOX_SB_SERVICE_FILE"; }
svc() {
    case "$1" in
        status) [[ "$SERVICE_RUNNING" == "true" ]] ;;
        stop) [[ "$STOP_ALLOWED" == "true" ]] || return 1; SERVICE_RUNNING=false ;;
        start) SERVICE_RUNNING=true ;;
        *) return 0 ;;
    esac
}
_singbox_runtime_healthy() {
    [[ "$HEALTH_MODE" == "success" ]] && return 0
    [[ "$(_sb_version)" == "1.13.12" ]]
}

seed_old_install
upgrade_singbox_transactional "$TARGET_VERSION" || fail "transactional upgrade unexpectedly failed"
assert_eq "$(_sb_version)" "$TARGET_VERSION" "new binary version"
assert_eq "$(cat "$SB_CONFIG")" '{"inbounds":[]}' "candidate configuration installed"
assert_eq "$(cat "$SONGBOX_SB_SERVICE_FILE")" "new-service" "service unit rebuilt"
[[ "$SERVICE_RUNNING" == "true" ]] || fail "running service was not restarted"
pass "successful upgrade atomically installs and verifies the candidate"

seed_old_install
HEALTH_MODE=rollback
if upgrade_singbox_transactional "$TARGET_VERSION"; then
    fail "upgrade unexpectedly succeeded after runtime verification failure"
fi
assert_eq "$(_sb_version)" "1.13.12" "old binary restored"
assert_eq "$(cat "$SB_CONFIG")" "old-config" "old configuration restored"
assert_eq "$(cat "$SONGBOX_SB_SERVICE_FILE")" "old-service" "old service unit restored"
[[ "$SERVICE_RUNNING" == "true" ]] || fail "old service was not restarted after rollback"
pass "runtime failure restores the previous binary, config, and service"

seed_old_install
HEALTH_MODE=success
STOP_ALLOWED=false
if upgrade_singbox_transactional "$TARGET_VERSION"; then
    fail "upgrade unexpectedly succeeded when the running service could not stop"
fi
assert_eq "$(_sb_version)" "1.13.12" "binary unchanged after stop failure"
assert_eq "$(cat "$SB_CONFIG")" "old-config" "config unchanged after stop failure"
assert_eq "$(cat "$SONGBOX_SB_SERVICE_FILE")" "old-service" "service unit unchanged after stop failure"
[[ "$SERVICE_RUNNING" == "true" ]] || fail "service state changed after stop failure"
pass "a service stop failure aborts before changing installed files"

echo "all transactional sing-box upgrade tests passed"
