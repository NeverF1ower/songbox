#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$1] == [$2]: $3"; }

[[ -n "${SONGBOX_TEST_JQ:-}" && -x "${SONGBOX_TEST_JQ}" ]] ||
    fail "set SONGBOX_TEST_JQ to a jq executable"

# The Windows CI harness has Bash coreutils but not jq/stat/du/sha256sum.
# These small adapters are test-only; Linux/VPS runs use the native tools.
jq() { "${SONGBOX_TEST_JQ}" "$@"; }
# Windows bsdtar writes CRLF to listings; Linux tar (the production target) writes LF.
tar() {
    case "${1:-}" in
        *t*) command tar "$@" | tr -d '\r' ;;
        *) command tar "$@" ;;
    esac
}
stat() {
    case "${1:-}" in
        -c%s|-f%z) shift; wc -c <"$1" | tr -d ' ' ;;
        *) return 1 ;;
    esac
}
du() {
    local mode="${1:-}" target="${2:-}" total=0 file bytes
    if [[ "$mode" == "-sk" ]]; then
        while IFS= read -r -d '' file; do
            bytes=$(wc -c <"$file"); ((total += bytes))
        done < <(find "$target" -type f -print0)
        printf '%s\t%s\n' "$(( (total + 1023) / 1024 ))" "$target"
    elif [[ "$mode" == "-h" ]]; then
        bytes=$(wc -c <"$target")
        printf '%sB\t%s\n' "$bytes" "$target"
    else
        return 1
    fi
}
chmod() { return 0; }
chown() { return 0; }

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/etc/vless-reality"
export SONGBOX_SITE_ROOT="$TEST_ROOT/var/www/decoy"
export SONGBOX_SYSTEM_SCRIPT="$TEST_ROOT/usr/local/bin/songbox.sh"
export SONGBOX_LEGACY_SYSTEM_SCRIPT="$TEST_ROOT/usr/local/bin/vless-server.sh"
export HOME="$TEST_ROOT/home"
mkdir -p "$SONGBOX_CFG_DIR/realm" "$SONGBOX_SITE_ROOT" "$HOME/.acme.sh"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"

_sha256_file() {
    if [[ ! -s "$1" ]]; then
        printf '%s\n' 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        certutil.exe -hashfile "$1" SHA256 2>/dev/null | sed -n '2p' | tr -d ' \r'
    fi
}
_log() { :; }
get_ipv4() { echo "192.0.2.10"; }
get_ipv6() { echo "2001:db8::10"; }
_realm_rule_count() { echo 1; }
check_dependencies() { return 0; }
stop_services() { return 0; }
start_services() { [[ -s "$DB_FILE" ]]; }
install_realm_core() { return 0; }
realm_start_service() { return 0; }
create_shortcut() { return 0; }
install_expire_cron() { return 0; }
sync_traffic_counters() { return 0; }
show_status() { return 0; }
show_realm_summary() { return 0; }
svc() { return 0; }

cat >"$DB_FILE" <<'JSON'
{
  "version": "0.1.0",
  "singbox": {
    "vless-reality": [
      {"port": 443, "uuid": "11111111-1111-4111-8111-111111111111", "users": []}
    ]
  },
  "snell": {},
  "chain_proxy": {"nodes": []},
  "routing_rules": [],
  "routing": {"warp_mode": "disabled", "direct_ip_version": "as_is"}
}
JSON
printf 'edge-node\n' >"$SONGBOX_CFG_DIR/node_name"
: >"$SONGBOX_CFG_DIR/no_firewall"
printf '[[endpoints]]\nlisten = "0.0.0.0:9000"\nremote = "198.51.100.2:9000"\n' \
    >"$SONGBOX_CFG_DIR/realm/config.toml"
printf '<!doctype html><title>Backup fixture</title><p>site-v1</p>\n' >"$SONGBOX_SITE_ROOT/index.html"
printf 'ACCOUNT_EMAIL=test@example.invalid\n' >"$HOME/.acme.sh/account.conf"

archive="$TEST_ROOT/songbox-current.tar.gz"
if ! do_backup "$archive" >"$TEST_ROOT/backup.log" 2>&1; then
    sed 's/^/# backup: /' "$TEST_ROOT/backup.log" >&2
    fail "current-format backup failed"
fi
assert_file "$archive"
do_list_backup "$archive" true >/dev/null 2>&1 || fail "current-format verification failed"
pass "current backup is self-verifying"

prepared="$TEST_ROOT/prepared-current"
mkdir -p "$prepared"
_prepare_restore_package "$archive" "$prepared" >/dev/null 2>&1 || fail "current-format prepare failed"
assert_file "$prepared/pkg/etc/db.json"
assert_file "$prepared/pkg/etc/realm/config.toml"
assert_file "$prepared/pkg/site/index.html"
assert_file "$prepared/pkg/acme/account.conf"
assert_eq "$(jq -r '.singbox["vless-reality"][0].port' "$prepared/pkg/etc/db.json")" "443" "current DB port"
pass "current payload restores config, realm, site, and ACME state"

# Legacy archives commonly contain an /etc/vless-reality tree plus /root/.acme.sh.
legacy_root="$TEST_ROOT/legacy-root/wrapper"
mkdir -p "$legacy_root/etc/vless-reality/realm" "$legacy_root/root/.acme.sh" "$legacy_root/var/www/decoy"
cp "$DB_FILE" "$legacy_root/etc/vless-reality/db.json"
cp "$SONGBOX_CFG_DIR/realm/config.toml" "$legacy_root/etc/vless-reality/realm/config.toml"
cp "$HOME/.acme.sh/account.conf" "$legacy_root/root/.acme.sh/account.conf"
cp "$SONGBOX_SITE_ROOT/index.html" "$legacy_root/var/www/decoy/index.html"
printf 'script_version=legacy\n' >"$legacy_root/meta.txt"
legacy_archive="$TEST_ROOT/songbox-legacy.tar.gz"
tar -czf "$legacy_archive" -C "$TEST_ROOT/legacy-root" wrapper || fail "legacy fixture creation failed"
legacy_prepared="$TEST_ROOT/prepared-legacy"
mkdir -p "$legacy_prepared"
_prepare_restore_package "$legacy_archive" "$legacy_prepared" >/dev/null 2>&1 || fail "legacy layout was rejected"
assert_file "$legacy_prepared/pkg/etc/db.json"
assert_file "$legacy_prepared/pkg/acme/account.conf"
assert_file "$legacy_prepared/pkg/site/index.html"
pass "legacy /etc/vless-reality archive layout is accepted"

# Repacking after changing db.json without updating manifest must be rejected.
tamper_root="$TEST_ROOT/tamper"
mkdir -p "$tamper_root/raw"
tar -xf "$archive" -C "$tamper_root/raw"
jq '.singbox["vless-reality"][0].port = 8443' "$tamper_root/raw/etc/db.json" >"$tamper_root/raw/etc/db.new"
mv "$tamper_root/raw/etc/db.new" "$tamper_root/raw/etc/db.json"
tampered="$TEST_ROOT/songbox-tampered.tar.gz"
tar -czf "$tampered" -C "$tamper_root/raw" .
mkdir -p "$tamper_root/check"
if _prepare_restore_package "$tampered" "$tamper_root/check" >/dev/null 2>&1; then
    fail "tampered manifest was accepted"
fi
pass "tampered backup is rejected"

# Adding a file that is absent from manifest.sha256 must also be rejected.
extra_root="$TEST_ROOT/extra"
mkdir -p "$extra_root/raw"
tar -xf "$archive" -C "$extra_root/raw"
printf '#!/bin/sh\necho unexpected\n' >"$extra_root/raw/acme/unlisted-hook.sh"
extra_archive="$TEST_ROOT/songbox-extra-file.tar.gz"
tar -czf "$extra_archive" -C "$extra_root/raw" .
mkdir -p "$extra_root/check"
if _prepare_restore_package "$extra_archive" "$extra_root/check" >/dev/null 2>&1; then
    fail "unlisted file was accepted by manifest verification"
fi
pass "files omitted from the manifest are rejected"

# Exercise the full atomic restore path in an isolated filesystem.
jq '.singbox["vless-reality"][0].port = 9999' "$DB_FILE" >"${DB_FILE}.new"
mv "${DB_FILE}.new" "$DB_FILE"
printf '<!doctype html><title>Current</title><p>site-current</p>\n' >"$SONGBOX_SITE_ROOT/index.html"
export SONGBOX_RESTORE_ASSUME_YES=1
do_restore "$archive" all >/dev/null 2>&1 || fail "atomic restore failed"
assert_eq "$(jq -r '.singbox["vless-reality"][0].port' "$DB_FILE")" "443" "restored DB port"
grep -q 'site-v1' "$SONGBOX_SITE_ROOT/index.html" || fail "site content was not restored"
pass "atomic restore replaces the isolated state"

# A failed service validation must put the previous state back.
jq '.singbox["vless-reality"][0].port = 9999' "$DB_FILE" >"${DB_FILE}.new"
mv "${DB_FILE}.new" "$DB_FILE"
start_services() { return 1; }
if do_restore "$archive" all >/dev/null 2>&1; then
    fail "restore unexpectedly succeeded when service validation failed"
fi
assert_eq "$(jq -r '.singbox["vless-reality"][0].port' "$DB_FILE")" "9999" "rollback DB port"
pass "failed service validation rolls back the previous state"

echo "all backup/restore tests passed"
