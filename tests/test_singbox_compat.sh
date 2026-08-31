#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

SB_TEST_BIN="${SONGBOX_TEST_SB_BIN:-}"
[[ -x "$SB_TEST_BIN" ]] || fail "set SONGBOX_TEST_SB_BIN to an executable sing-box binary"

export SONGBOX_SOURCE_ONLY=1
export SONGBOX_CFG_DIR="$TEST_ROOT/etc/vless-reality"
export SONGBOX_SB_BIN="$SB_TEST_BIN"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"

_log() { :; }
_has_ipv6() { return 1; }
_can_dual_stack() { return 1; }

init_db || fail "database initialization failed"
register_protocol socks '{
  "port": 1080,
  "auth_mode": "password",
  "listen_addr": "127.0.0.1",
  "username": "audit",
  "password": "audit-only"
}' || fail "SOCKS fixture registration failed"

_db_apply '
  .chain_proxy.nodes = [{
    name:"upstream", type:"socks", server:"proxy.example.com", port:1081,
    username:"chain", password:"chain-only"
  }]
  | .routing_rules = [
      {id:"chain-domain", type:"domain", outbound:"chain:upstream", match:"example.com", ip_version:"as_is"},
      {id:"direct-v4", type:"domain", outbound:"direct", match:"example.net", ip_version:"ipv4_only"}
    ]
' || fail "routing fixture creation failed"

OUTPUT="$TEST_ROOT/singbox.json"
generate_singbox_config "$OUTPUT" || fail "songbox failed to generate a compatible configuration"

jq -e '.dns.servers[0].type == "local" and .dns.servers[0].tag == "dns-local"' "$OUTPUT" >/dev/null ||
    fail "new DNS server format was not generated"
jq -e '.route.default_domain_resolver == "dns-local"' "$OUTPUT" >/dev/null ||
    fail "default domain resolver is missing"
jq -e '[.outbounds[] | select(.tag == "direct-ipv4")][0].domain_resolver.strategy == "ipv4_only"' "$OUTPUT" >/dev/null ||
    fail "direct outbound did not use domain_resolver"
if jq -e '.. | objects | select(has("domain_strategy"))' "$OUTPUT" >/dev/null; then
    fail "legacy domain_strategy leaked into the generated configuration"
fi
"$SB_TEST_BIN" check -c "$OUTPUT" || fail "sing-box rejected the generated configuration"
pass "generated configuration passes $("$SB_TEST_BIN" version | head -1)"

legacy=$(SONGBOX_SB_VERSION_OVERRIDE=1.11.15 _sb_apply_domain_strategy '{"type":"direct","tag":"direct"}' ipv4_only)
modern=$(SONGBOX_SB_VERSION_OVERRIDE=1.14.0 _sb_apply_domain_strategy '{"type":"direct","tag":"direct"}' ipv4_only)
jq -e '.domain_strategy == "ipv4_only" and (.domain_resolver == null)' <<<"$legacy" >/dev/null ||
    fail "pre-1.12 compatibility output changed"
jq -e '.domain_strategy == null and .domain_resolver.server == "dns-local"' <<<"$modern" >/dev/null ||
    fail "1.14 domain resolver output is invalid"
pass "version-aware domain resolution preserves old VPS compatibility"

echo "all sing-box compatibility tests passed"
