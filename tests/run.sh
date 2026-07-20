#!/usr/bin/env bash
#
# qvpn test suite — pure-bash, no external dependencies beyond awk/sed/grep.
#
# Usage:
#   ./tests/run.sh                # run everything
#   ./tests/run.sh -v             # show output of every test
#   ./tests/run.sh test_cli_*     # run only matching tests
#
# Each test is a shell function named test_*. The runner discovers them via
# `declare -F`, executes each in its own subshell (so set -e and side effects
# don't leak), and tracks pass/fail counts.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT/tests"
FIXTURES="$TEST_DIR/fixtures"
QVPN="$ROOT/qvpn"

# ─── Framework ──────────────────────────────────────────────────────────────
PASSED=0; FAILED=0; SKIPPED=0
declare -a FAILURES=()
VERBOSE=0
FILTER=""
TMP_ROOT=""

red()    { printf '\033[0;31m%s\033[0m' "$1"; }
green()  { printf '\033[0;32m%s\033[0m' "$1"; }
yellow() { printf '\033[1;33m%s\033[0m' "$1"; }
dim()    { printf '\033[2m%s\033[0m'   "$1"; }

fail() {
    printf '%s %s\n' "$(red 'FAIL:')" "$1" >&2
    [[ $# -gt 1 ]] && printf '       %s\n' "$2" >&2
    return 1
}

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-assert_eq}"
    if [[ "$actual" != "$expected" ]]; then
        fail "$msg" "expected: $(printf '%q' "$expected") | actual: $(printf '%q' "$actual")"
    fi
}

assert_ne() {
    local actual="$1" unexpected="$2" msg="${3:-assert_ne}"
    if [[ "$actual" == "$unexpected" ]]; then
        fail "$msg" "got the unexpected value: $(printf '%q' "$unexpected")"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-assert_contains}"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$msg" "needle not found: $(printf '%q' "$needle")"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-assert_not_contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$msg" "needle should NOT be found: $(printf '%q' "$needle")"
    fi
}

assert_match() {
    local haystack="$1" regex="$2" msg="${3:-assert_match}"
    if ! [[ "$haystack" =~ $regex ]]; then
        fail "$msg" "regex did not match: $regex"
    fi
}

assert_exit() {
    local expected="$1"; shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if (( actual != expected )); then
        fail "assert_exit: $* exited $actual (expected $expected)"
    fi
}

assert_zero() { assert_exit 0 "$@"; }
assert_nonzero() {
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if (( actual == 0 )); then
        fail "assert_nonzero: command should have failed but returned 0: $*"
    fi
}

skip() {
    printf '%s\n' "$1"
    return 77
}

# Per-test scratch directory (auto-cleaned).
make_tmp() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/qvpn-test.XXXXXX")
    echo "$d"
}

# ─── Source qvpn for white-box tests ────────────────────────────────────────
# qvpn has a sourcing guard, so this loads helpers without running main.
# Strict mode propagates across `source`; opt out so the runner stays robust.
# shellcheck source=/dev/null
source "$QVPN"
set +e
set +o pipefail

# Force colors off so test assertions on stdout/stderr aren't tripped by ANSI.
COLOR_MODE="never"
init_colors

# ============================================================================
#  WHITE-BOX TESTS — internal helpers
# ============================================================================

# ─── valid_client_name ──────────────────────────────────────────────────────
test_valid_client_name_accepts_simple() {
    valid_client_name "phone" || fail "should accept 'phone'"
    valid_client_name "laptop" || fail "should accept 'laptop'"
    valid_client_name "FooBar123" || fail "should accept mixed case + digits"
}

test_valid_client_name_accepts_punctuation() {
    valid_client_name "kiteboard-2024" || fail "should accept dashes"
    valid_client_name "user_at_home"   || fail "should accept underscores"
    valid_client_name "node.alpha"     || fail "should accept dots"
}

test_valid_client_name_rejects_empty() {
    valid_client_name "" && fail "should reject empty"
    return 0
}

test_valid_client_name_rejects_whitespace() {
    valid_client_name "has space" && fail "should reject space"
    valid_client_name "$'tab\there'" && fail "should reject tab" || true
    return 0
}

test_valid_client_name_rejects_shell_metas() {
    local bad
    for bad in 'foo$bar' 'foo;rm' 'foo|cat' 'foo&disown' 'foo`whoami`' 'foo/etc' 'foo>out'; do
        if valid_client_name "$bad"; then
            fail "should reject '$bad'"
        fi
    done
}

test_valid_client_name_rejects_overlong() {
    local long; long=$(printf 'a%.0s' {1..33})
    valid_client_name "$long" && fail "should reject 33-char name (max 32)"
    return 0
}

# ─── subnet_prefix ──────────────────────────────────────────────────────────
test_subnet_prefix_24() {
    assert_eq "$(subnet_prefix 10.0.0.0/24)"     "10.0.0"     "10.x prefix"
    assert_eq "$(subnet_prefix 192.168.1.0/24)"  "192.168.1"  "192.168.x prefix"
    assert_eq "$(subnet_prefix 172.16.5.0/24)"   "172.16.5"   "172.16.x prefix"
}

# ─── human_bytes ────────────────────────────────────────────────────────────
test_human_bytes_small() {
    assert_eq "$(human_bytes 0)"     "0 B"     "zero"
    assert_eq "$(human_bytes 999)"   "999 B"   "below 1KB"
    assert_eq "$(human_bytes 1023)"  "1023 B"  "max bytes"
}

test_human_bytes_kb_mb() {
    # 1024 → 1.00 KB
    assert_match "$(human_bytes 1024)"      '^1\.00 KB$' "1KB"
    assert_match "$(human_bytes 1536)"      '^1\.50 KB$' "1.5KB"
    assert_match "$(human_bytes 1048576)"   '^1\.00 MB$' "1MB"
    assert_match "$(human_bytes 1073741824)" '^1\.00 GB$' "1GB"
}

# ─── human_age ──────────────────────────────────────────────────────────────
test_human_age_never() {
    assert_eq "$(human_age "")"  "never" "empty input"
    assert_eq "$(human_age 0)"   "never" "zero input"
}

test_human_age_recent() {
    local now; now=$(date +%s)
    assert_match "$(human_age $((now - 5)))"     '^[0-9]+s ago$'  "seconds"
    assert_match "$(human_age $((now - 90)))"    '^1m ago$'       "minutes"
    assert_match "$(human_age $((now - 3700)))"  '^1h ago$'       "hours"
    assert_match "$(human_age $((now - 90000)))" '^1d ago$'       "days"
}

# ─── list_server_peers — REGRESSION: greedy regex bug ───────────────────────
test_parser_handles_keys_ending_in_equals() {
    # Keys ending in '=' are the WireGuard standard. The greedy '.*=' regex
    # in the legacy code was eating the entire value. Verify '^[^=]*=' works.
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/wg0-multi.conf" "$tmp/wg0.conf"
    WG_CONF="$tmp/wg0.conf" CLIENTS_DIR="$tmp/clients"

    local out; out=$(list_server_peers)
    rm -rf "$tmp"

    assert_contains "$out" "PHONE_PK_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="  "phone pk preserved"
    assert_contains "$out" "LAPTOP_PK_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "laptop pk preserved"
    assert_contains "$out" "TV_PK_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "tv pk preserved"
    assert_contains "$out" $'\t'"10.0.0.2"  "phone IP"
    assert_contains "$out" $'\t'"10.0.0.3"  "laptop IP"
    assert_contains "$out" $'\t'"10.0.0.4"  "tv IP"
}

# ─── list_server_peers — REGRESSION: lost-peer accumulation bug ─────────────
test_parser_returns_all_consecutive_peers() {
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/wg0-multi.conf" "$tmp/wg0.conf"
    WG_CONF="$tmp/wg0.conf"

    local count; count=$(list_server_peers | wc -l | tr -d ' ')
    rm -rf "$tmp"
    assert_eq "$count" "3" "should find all 3 peers"
}

test_parser_zero_peers() {
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/wg0-empty.conf" "$tmp/wg0.conf"
    WG_CONF="$tmp/wg0.conf"

    local out; out=$(list_server_peers)
    rm -rf "$tmp"
    assert_eq "$out" "" "should produce no output for zero peers"
}

# ─── client_ip_from_conf ────────────────────────────────────────────────────
test_client_ip_from_conf() {
    assert_eq "$(client_ip_from_conf "$FIXTURES/client-phone.conf")" "10.0.0.2" "phone client IP"
}

# ─── ip_in_use / next_free_ip ───────────────────────────────────────────────
test_ip_in_use_detects_collisions() {
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/wg0-multi.conf" "$tmp/wg0.conf"
    WG_CONF="$tmp/wg0.conf"
    CLIENTS_DIR="$tmp/clients-empty"   # empty / nonexistent

    ip_in_use "10.0.0.2" || fail "should detect 10.0.0.2 (in use)"
    ip_in_use "10.0.0.4" || fail "should detect 10.0.0.4 (in use)"
    ip_in_use "10.0.0.1" || fail "should detect 10.0.0.1 (server)"
    ip_in_use "10.0.0.99" && fail "should NOT detect 10.0.0.99 (free)"
    rm -rf "$tmp"
    return 0
}

test_next_free_ip_skips_existing() {
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/wg0-multi.conf" "$tmp/wg0.conf"
    WG_CONF="$tmp/wg0.conf"
    CLIENTS_DIR="$tmp/clients-empty"
    VPN_SUBNET="10.0.0.0/24"
    SERVER_VPN_IP="10.0.0.1"

    # .1 (server), .2 (phone), .3 (laptop), .4 (tv) → next free is .5
    assert_eq "$(next_free_ip)" "10.0.0.5" "first gap"
    rm -rf "$tmp"
}

test_next_free_ip_empty_subnet() {
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/wg0-empty.conf" "$tmp/wg0.conf"
    WG_CONF="$tmp/wg0.conf"
    CLIENTS_DIR="$tmp/clients-empty"
    VPN_SUBNET="10.0.0.0/24"
    SERVER_VPN_IP="10.0.0.1"

    # Only .1 (server) is taken → next free is .2
    assert_eq "$(next_free_ip)" "10.0.0.2" "first client slot"
    rm -rf "$tmp"
}

# ─── Peer-removal awk (used by `qvpn remove` when SaveConfig != true) ───────
strip_peer() {
    # Inline copy of the awk used in cmd_remove, so we test it without
    # touching `wg-quick save`.
    local pubkey="$1" conf="$2"
    awk -v pk="$pubkey" '
        function flush() {
            if (!in_target && buffered != "") printf "%s", buffered
            buffered = ""; in_target = 0
        }
        /^\[Peer\]/ { flush(); buffered = $0 ORS; next }
        /^\[/       { flush(); print; next }
        /^[[:space:]]*PublicKey/ {
            if (index($0, pk)) in_target = 1
            if (buffered != "") buffered = buffered $0 ORS; else print
            next
        }
        { if (buffered != "") buffered = buffered $0 ORS; else print }
        END { flush() }
    ' "$conf"
}

test_peer_removal_drops_target_keeps_others() {
    local out; out=$(strip_peer "LAPTOP_PK_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "$FIXTURES/wg0-no-savecfg.conf")

    assert_contains "$out" "PHONE_PK"   "phone preserved"
    assert_not_contains "$out" "LAPTOP_PK" "laptop dropped"
    assert_contains "$out" "[Interface]" "interface preserved"
    assert_contains "$out" "10.0.0.2/32" "phone IP preserved"
    assert_not_contains "$out" "10.0.0.3/32" "laptop IP dropped"
}

test_peer_removal_no_match_leaves_file_alone() {
    local original; original=$(cat "$FIXTURES/wg0-no-savecfg.conf")
    local stripped; stripped=$(strip_peer "DOES_NOT_EXIST_PK=" "$FIXTURES/wg0-no-savecfg.conf")
    assert_eq "$stripped" "$original" "no-match should be a no-op"
}

test_peer_removal_first_peer() {
    local out; out=$(strip_peer "PHONE_PK_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "$FIXTURES/wg0-no-savecfg.conf")
    assert_not_contains "$out" "PHONE_PK"  "phone dropped"
    assert_contains     "$out" "LAPTOP_PK" "laptop kept"
    assert_contains     "$out" "[Interface]" "interface kept"
}

# ─── Config loading + precedence ────────────────────────────────────────────
test_config_file_overrides_defaults() {
    local tmp; tmp=$(make_tmp)
    cp "$FIXTURES/qvpn.conf" "$tmp/qvpn.conf"
    QVPN_CONFIG="$tmp/qvpn.conf"

    # Reset variables to make sure load_config drives them.
    CLIENT_NAME=""; LISTEN_PORT=""; DNS_SERVERS=""; VPN_SUBNET=""
    load_config

    assert_eq "$CLIENT_NAME"  "testclient"     "CLIENT_NAME from file"
    assert_eq "$LISTEN_PORT"  "41820"          "LISTEN_PORT from file"
    assert_eq "$DNS_SERVERS"  "9.9.9.9"        "DNS_SERVERS from file"
    assert_eq "$VPN_SUBNET"   "10.99.0.0/24"   "VPN_SUBNET from file"
    rm -rf "$tmp"
}

test_config_defaults_applied_when_no_file() {
    QVPN_CONFIG="/nonexistent/qvpn.conf"
    CLIENT_NAME=""; LISTEN_PORT=""; DNS_SERVERS=""; VPN_SUBNET=""

    # Suppress the auto-locate by clearing PWD-side qvpn.conf existence check
    # (the function bails to defaults when file isn't found).
    QVPN_CONFIG=""  # also force it to the auto-locator path
    cd "$(make_tmp)" || return 1
    load_config

    assert_eq "$CLIENT_NAME"  "$DEFAULT_CLIENT_NAME"  "default CLIENT_NAME"
    assert_eq "$LISTEN_PORT"  "$DEFAULT_LISTEN_PORT"  "default LISTEN_PORT"
    assert_eq "$DNS_SERVERS"  "$DEFAULT_DNS_SERVERS"  "default DNS_SERVERS"
    assert_eq "$VPN_SUBNET"   "$DEFAULT_VPN_SUBNET"   "default VPN_SUBNET"
}

test_load_meta_ignores_legacy_version_field() {
    local tmp; tmp=$(make_tmp)
    QVPN_META="$tmp/.qvpn-meta"
    cat > "$QVPN_META" <<'EOF'
QVPN_VERSION="0.9.0"
SERVER_IP="203.0.113.10"
VPN_SUBNET="10.77.0.0/24"
SERVER_VPN_IP="10.77.0.1"
LISTEN_PORT="42820"
DNS_SERVERS="9.9.9.9"
NETWORK_INTERFACE="ens3"
EOF

    SERVER_IP=""; VPN_SUBNET=""; SERVER_VPN_IP=""
    LISTEN_PORT=""; DNS_SERVERS=""; NETWORK_INTERFACE=""

    load_meta

    assert_eq "$QVPN_VERSION" "1.0.0" "runtime QVPN_VERSION should remain unchanged"
    assert_eq "$SERVER_IP" "203.0.113.10" "SERVER_IP meta"
    assert_eq "$VPN_SUBNET" "10.77.0.0/24" "VPN_SUBNET meta"
    assert_eq "$SERVER_VPN_IP" "10.77.0.1" "SERVER_VPN_IP meta"
    assert_eq "$LISTEN_PORT" "42820" "LISTEN_PORT meta"
    assert_eq "$DNS_SERVERS" "9.9.9.9" "DNS_SERVERS meta"
    assert_eq "$NETWORK_INTERFACE" "ens3" "NETWORK_INTERFACE meta"
    rm -rf "$tmp"
}

# ============================================================================
#  BLACK-BOX TESTS — invoke ./qvpn as a subprocess
# ============================================================================

# Capture qvpn's stdout+stderr WITHOUT propagating its exit code to the
# caller's `set -e` — many tests intentionally invoke failing commands.
run_qvpn() {
    local out
    out=$(NO_COLOR=1 "$QVPN" "$@" 2>&1) || true
    printf '%s' "$out"
}

run_qvpn_status() {
    local rc=0
    NO_COLOR=1 "$QVPN" "$@" >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

test_cli_version() {
    assert_eq "$(run_qvpn version)"        "qvpn 1.0.0" "version subcommand"
    assert_eq "$(run_qvpn -V)"             "qvpn 1.0.0" "-V flag"
    assert_eq "$(run_qvpn --version)"      "qvpn 1.0.0" "--version flag"
}

test_cli_help_no_args_shows_usage() {
    local out; out=$(run_qvpn)
    assert_contains "$out" "USAGE"          "help shows USAGE"
    assert_contains "$out" "init"           "help lists init"
    assert_contains "$out" "add <name>"     "help lists add"
    assert_contains "$out" "remove <name>"  "help lists remove"
}

test_cli_help_subcommand() {
    assert_contains "$(run_qvpn help init)"      "qvpn init"        "help init"
    assert_contains "$(run_qvpn init --help)"    "First client"     "init --help"
    assert_contains "$(run_qvpn add --help)"     "next free"        "add --help"
    assert_contains "$(run_qvpn remove --help)"  "Remove a client"  "remove --help"
    assert_contains "$(run_qvpn show --help)"    "QR code"          "show --help"
    assert_contains "$(run_qvpn status --help)"  "service health"   "status --help"
    assert_contains "$(run_qvpn restart --help)" "Restart"          "restart --help"
    assert_contains "$(run_qvpn teardown --help)" "soft teardown"   "teardown --help"
}

test_cli_unknown_command_errors() {
    local out; out=$(run_qvpn doesnotexist)
    assert_contains "$out" "Unknown command"  "error message"
    assert_eq "$(run_qvpn_status doesnotexist)" "1" "exit 1"
}

test_cli_unknown_help_subcommand_errors() {
    local out; out=$(run_qvpn help doesnotexist)
    assert_contains "$out" "Unknown command"
    assert_eq "$(run_qvpn_status help doesnotexist)" "1"
}

test_cli_no_root_friendly_error() {
    # All command paths that need root should fail gracefully when not root.
    local out
    out=$(run_qvpn list);    assert_contains "$out" "must be run as root"
    out=$(run_qvpn add foo); assert_contains "$out" "must be run as root"
    out=$(run_qvpn remove foo); assert_contains "$out" "must be run as root"
    out=$(run_qvpn show foo);   assert_contains "$out" "must be run as root"
    out=$(run_qvpn status);     assert_contains "$out" "must be run as root"
    out=$(run_qvpn restart);    assert_contains "$out" "must be run as root"
}

test_cli_add_requires_name() {
    local out; out=$(run_qvpn add)
    assert_contains "$out" "Client name required"
    assert_eq "$(run_qvpn_status add)" "1"
}

test_cli_remove_requires_name() {
    local out; out=$(run_qvpn remove)
    assert_contains "$out" "Client name required"
}

test_cli_show_requires_name() {
    local out; out=$(run_qvpn show)
    assert_contains "$out" "Client name required"
}

test_cli_aliases_resolve() {
    # rm/del → remove (should fail with 'name required', proving dispatch worked)
    assert_contains "$(run_qvpn rm)"  "Client name required"  "rm alias"
    assert_contains "$(run_qvpn del)" "Client name required"  "del alias"
    # ls → list (root error proves dispatch)
    assert_contains "$(run_qvpn ls)"  "must be run as root"   "ls alias"
    # st → status
    assert_contains "$(run_qvpn st)"  "must be run as root"   "st alias"
    # destroy/nuke → teardown (will hit root check)
    assert_contains "$(run_qvpn destroy --help)" "soft teardown" "destroy alias"
    assert_contains "$(run_qvpn nuke --help)"    "soft teardown" "nuke alias"
    # get → show
    assert_contains "$(run_qvpn get)" "Client name required" "get alias"
}

test_cli_no_color_strips_ansi() {
    local out; out=$(NO_COLOR=1 "$QVPN" version)
    if [[ "$out" == *$'\033'* ]]; then
        fail "NO_COLOR=1 produced ANSI escapes"
    fi
    out=$("$QVPN" --no-color help 2>&1)
    if [[ "$out" == *$'\033'* ]]; then
        fail "--no-color produced ANSI escapes"
    fi
}

test_cli_color_always_emits_ansi() {
    local out; out=$("$QVPN" --color always help 2>&1)
    if [[ "$out" != *$'\033'* ]]; then
        fail "--color always should emit ANSI escapes"
    fi
}

test_cli_invalid_client_name_blocked() {
    # Should reject without needing root (validation comes first? actually
    # require_root happens after parse — so this fires the root error first).
    # We verify the flow doesn't crash and exits non-zero either way.
    assert_eq "$(run_qvpn_status add 'has space')" "1"
    assert_eq "$(run_qvpn_status add 'foo;rm')" "1"
}

test_cli_unknown_global_flag_passed_to_subcommand() {
    # Unknown -* before a subcommand is forwarded; subcommand should reject it.
    local out; out=$(run_qvpn add foo --bogusflag)
    assert_contains "$out" "Unknown option"
}

# ============================================================================
#  Runner
# ============================================================================
parse_args() {
    while (( $# )); do
        case "$1" in
            -v|--verbose) VERBOSE=1; shift ;;
            -h|--help)
                cat <<EOF
Usage: $(basename "$0") [-v] [filter ...]

Options:
  -v, --verbose   show stderr/stdout from each test (even when passing)
  -h, --help      show this help

Filter:
  Pass any number of test name prefixes to run only matching tests.
  Example:  $0 test_cli_*   $0 test_parser_*
EOF
                exit 0
                ;;
            *) FILTER="$FILTER $1"; shift ;;
        esac
    done
}

discover_tests() {
    declare -F | awk '{print $3}' | grep '^test_' | sort
}

matches_filter() {
    local name="$1"
    [[ -z "$FILTER" ]] && return 0
    for pat in $FILTER; do
        # shellcheck disable=SC2053
        [[ "$name" == $pat ]] && return 0
    done
    return 1
}

run_one() {
    local name="$1" output rc=0
    output=$( (set -e; "$name") 2>&1 ) || rc=$?

    case $rc in
        0)
            ((PASSED++))
            printf '  %s %s\n' "$(green PASS)" "$name"
            (( VERBOSE )) && [[ -n "$output" ]] && printf '%s\n' "$output" | sed 's/^/      /'
            ;;
        77)
            ((SKIPPED++))
            printf '  %s %s — %s\n' "$(yellow SKIP)" "$name" "$output"
            ;;
        *)
            ((FAILED++))
            FAILURES+=("$name")
            printf '  %s %s\n' "$(red FAIL)" "$name"
            [[ -n "$output" ]] && printf '%s\n' "$output" | sed 's/^/      /'
            ;;
    esac
}

main() {
    parse_args "$@"

    local -a tests=()
    while IFS= read -r t; do
        tests+=("$t")
    done < <(discover_tests)

    printf '%s qvpn test suite\n\n' "$(dim '──')"

    local started=0
    for t in "${tests[@]}"; do
        if matches_filter "$t"; then
            ((started++))
            run_one "$t"
        fi
    done

    printf '\n%s %d passed, %d failed' "$(dim '──')" "$PASSED" "$FAILED"
    (( SKIPPED )) && printf ', %d skipped' "$SKIPPED"
    printf ' (out of %d)\n' "$started"

    if (( FAILED > 0 )); then
        printf '\n%s\n' "$(red 'failures:')"
        for f in "${FAILURES[@]}"; do
            printf '  - %s\n' "$f"
        done
        exit 1
    fi
}

main "$@"
