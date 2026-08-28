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
export SONGBOX_SITE_ROOT="$TEST_ROOT/var/www/decoy"
mkdir -p "$SONGBOX_CFG_DIR" "$SONGBOX_SITE_ROOT"

# shellcheck source=../songbox.sh
source "$ROOT_DIR/songbox.sh"

[[ ${#DECOY_TPL_NAME[@]} -eq 9 ]] || fail "v2ray-agent template count is not 9"
[[ ${#DECOY_TPL_SHA256[@]} -eq 9 ]] || fail "v2ray-agent digest count is not 9"
count=0
while read -r digest filename; do
    [[ -z "$digest" || "$digest" == \#* ]] && continue
    [[ "$filename" =~ ^html([1-9])\.zip$ ]] || fail "invalid manifest filename: $filename"
    n="${BASH_REMATCH[1]}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid manifest digest: $filename"
    assert_eq "${DECOY_TPL_SHA256[$n]}" "$digest" "manifest digest $filename"
    ((count++))
done <"$ROOT_DIR/assets/decoy-sites/v2ray-agent.sha256"
[[ "$count" -eq 9 ]] || fail "integrity manifest does not list 9 archives"
pass "nine pinned v2ray-agent templates have matching SHA-256 values"

assert_eq "$(_decoy_tpl_description 'v2ray-agent:6')" "v2ray-agent 模板 6 (mikutap 互动页)" "new template marker"
assert_eq "$(_decoy_tpl_description '6')" "v2ray-agent 旧版模板 6 (mikutap 互动页)" "legacy numeric marker"
assert_eq "$(_decoy_tpl_description 'docs.html')" "songbox 轻量模板 2 (产品文档页)" "v0.1.0 marker"
assert_eq "$(_decoy_tpl_description 'songbox:3')" "songbox 轻量模板 3 (个人作品页)" "new songbox marker"
pass "new, legacy, and v0.1.0 template markers remain readable"

# Optional full fixture test. The local audit passes the nine pinned upstream archives
# through the real download/hash/archive/extract/install function without network access.
if [[ -n "${SONGBOX_TEMPLATE_FIXTURE_DIR:-}" ]]; then
    [[ -d "$SONGBOX_TEMPLATE_FIXTURE_DIR" ]] || fail "fixture directory does not exist"
    _log() { :; }
    _sha256_file() {
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" | awk '{print $1}'
        else
            certutil.exe -hashfile "$1" SHA256 2>/dev/null | sed -n '2p' | tr -d ' \r'
        fi
    }
    stat() {
        case "${1:-}" in
            -c%s|-f%z) shift; wc -c <"$1" | tr -d ' ' ;;
            *) command stat "$@" ;;
        esac
    }
    unzip() {
        case "${1:-}" in
            # Windows bsdtar renders some legacy non-UTF-8 names as \123 escapes;
            # production Linux uses unzip -Z1 and returns the decoded filename.
            -Z1) command tar -tf "$2" | sed -E 's/\\[0-7]{3}//g' | tr -d '\r' ;;
            -oq)
                local archive="$2" destination=""
                shift 2
                while [[ $# -gt 0 ]]; do
                    case "$1" in -d) destination="$2"; shift 2 ;; *) shift ;; esac
                done
                [[ -n "$destination" ]] || return 1
                command tar -xf "$archive" -C "$destination"
                ;;
            *) return 1 ;;
        esac
    }
    _raw_mirrors() { printf '%s\n' "$1"; }
    curl() {
        local out="" url=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -o) out="$2"; shift 2 ;;
                https://*) url="$1"; shift ;;
                *) shift ;;
            esac
        done
        [[ -n "$out" && -n "$url" ]] || return 1
        cp "$SONGBOX_TEMPLATE_FIXTURE_DIR/${url##*/}" "$out"
    }
    for n in 1 2 3 4 5 6 7 8 9; do
        if ! _install_v2ray_agent_decoy_template "$n" >"$TEST_ROOT/template-$n.log" 2>&1; then
            sed 's/^/# template: /' "$TEST_ROOT/template-$n.log" >&2
            fail "fixture template $n failed installation"
        fi
        [[ -s "$SONGBOX_SITE_ROOT/index.html" ]] || fail "template $n has no installed index.html"
        assert_eq "$(cat "$SONGBOX_SITE_ROOT/.tpl")" "v2ray-agent:$n" "installed marker $n"
    done
    pass "all nine upstream archives pass the production install pipeline"
fi

echo "all decoy template tests passed"
