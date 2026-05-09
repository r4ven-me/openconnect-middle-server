#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="occlient"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

exec &> >(logging)

readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.*}.lock"

readonly VPN_BIN="openconnect"
readonly VPNC_SCRIPT="bash -c 'CISCO_SPLIT_INC=0 INTERNAL_IP4_DNS= exec /usr/share/vpnc-scripts/vpnc-script'"

readonly REQUIRED_COMMANDS=(
    awk
    base64
    flock
    grep
    ip
    nft
    openconnect
    ping
    ss
    timeout
)

VPN_PID=""
LOCK_FD=""

CURRENT_VPN_INDEX=0

: "${OC_CLIENT_IFACE:?Missing OC_CLIENT_IFACE}"
: "${OC_CLIENT_CHECK_INTERVAL:?Missing OC_CLIENT_CHECK_INTERVAL}"
: "${OC_CLIENT_CHECK_THRESHOLD:?Missing OC_CLIENT_CHECK_THRESHOLD}"
: "${OC_CLIENT_COUNT:?Missing OC_CLIENT_COUNT}"
: "${OC_IPV4_NET:?Missing OC_IPV4_NET}"
: "${OC_IPV4_MASK:?Missing OC_IPV4_MASK}"
: "${OC_SRV_PORT:=443}"

require_non_negative_int OC_CLIENT_CHECK_INTERVAL || exit 1
require_non_negative_int OC_CLIENT_CHECK_THRESHOLD || exit 1
require_positive_int OC_CLIENT_COUNT || exit 1
OC_IPV4_CIDR="$(ipv4_cidr "$OC_IPV4_NET" "$OC_IPV4_MASK")" || die "Invalid IPv4 network/netmask: ${OC_IPV4_NET}/${OC_IPV4_MASK}"

readonly VPN_IFACE="$OC_CLIENT_IFACE"
readonly CHECK_INTERVAL="$OC_CLIENT_CHECK_INTERVAL"
readonly CHECK_THRESHOLD="$OC_CLIENT_CHECK_THRESHOLD"
readonly VPN_COUNT="$OC_CLIENT_COUNT"
readonly LOCAL_OCSERV_PORT="$OC_SRV_PORT"
readonly OC_IPV4_CIDR

setup_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"

    if ! flock -n "$LOCK_FD"; then
        local pid="unknown"

        read -r pid < "$LOCK_FILE" || true

        die "Another instance already running (PID=${pid})"
    fi

    : > "/proc/self/fd/$LOCK_FD"

    printf '%s\n' "$$" >&"$LOCK_FD"
}

cleanup() {
    local rc=$?

    trap - EXIT INT TERM HUP QUIT

    disconnect_vpn || true
    cleanup_routes || true

    if [[ -n "${LOCK_FD:-}" ]]; then
        exec {LOCK_FD}>&-
    fi

    exit "$rc"
}

trap cleanup EXIT INT TERM HUP QUIT

check_runtime() {
    require_commands "${REQUIRED_COMMANDS[@]}" || exit 1
    # require_files "$VPNC_SCRIPT" || exit 1
}

wait_for_ocserv_port() {
    until ss -H -tln "sport = :${LOCAL_OCSERV_PORT}" | grep -q .; do
        log_info "Waiting for local ocserv TCP/${LOCAL_OCSERV_PORT} listener..."
        sleep 5
    done
}

load_vpn_profile() {
    local idx="$CURRENT_VPN_INDEX"
    local var

    var="OC_CLIENT_${idx}_SSL_FLAG"
    VPN_SSL_FLAG="${!var:-true}"

    var="OC_CLIENT_${idx}_SERVER"
    VPN_ADDRESS="${!var:-}"

    var="OC_CLIENT_${idx}_SERVER_PORT"
    VPN_PORT="${!var:-}"

    var="OC_CLIENT_${idx}_CERT_FILE"
    VPN_CERT_FILE="${!var:-}"

    var="OC_CLIENT_${idx}_CERT_PASS"
    VPN_CERT_PASS="${!var:-}"

    var="OC_CLIENT_${idx}_CHECK_HOST"
    VPN_CHECK_HOST="${!var:-}"

    [[ -n "$VPN_ADDRESS" ]] || die "VPN_ADDRESS missing for profile [$idx]"
    [[ -n "$VPN_PORT" ]] || die "VPN_PORT missing for profile [$idx]"
    require_files "$VPN_CERT_FILE" || die "Certificate file missing for profile [$idx]"
    [[ -n "$VPN_CERT_PASS" ]] || die "VPN_CERT_PASS missing for profile [$idx]"
    [[ -n "$VPN_CHECK_HOST" ]] || die "VPN_CHECK_HOST missing for profile [$idx]"

    log_info \
        "Loaded VPN profile [$idx]: ${VPN_ADDRESS}:${VPN_PORT}"
}

next_vpn_profile() {
    if (( VPN_COUNT < 2 )); then
        log_warn "No alternate VPN profiles configured (OC_CLIENT_COUNT=${VPN_COUNT})"
        return 1
    fi

    (( CURRENT_VPN_INDEX = (CURRENT_VPN_INDEX + 1) % VPN_COUNT ))

    load_vpn_profile
}

disconnect_vpn() {
    if [[ -n "${VPN_PID:-}" ]] && kill -0 "$VPN_PID" 2> /dev/null; then
        log_info "Stopping VPN process PID=$VPN_PID"

        kill "$VPN_PID" 2> /dev/null || true

        timeout 15 bash -c "
            while kill -0 $VPN_PID 2> /dev/null; do
                sleep 1
            done
        " || true

        wait "$VPN_PID" 2> /dev/null || true
    fi

    VPN_PID=""
}

wait_for_interface() {
    local timeout_sec="${1:-15}"
    local elapsed=0

    while (( elapsed < timeout_sec )); do
        if ip link show "$VPN_IFACE" &> /dev/null; then
            return 0
        fi

        sleep 1
        (( ++elapsed ))
    done

    return 1
}

connect_vpn() {
    local cert_pass

    log_info \
        "Connecting to ${VPN_ADDRESS}:${VPN_PORT} (iface=${VPN_IFACE})"

    cert_pass="$(
        printf '%s' "$VPN_CERT_PASS" | base64 -d
    )" || die "Failed to decode VPN password"

    if is_true "$VPN_SSL_FLAG"; then
        printf '%s\n' "$cert_pass"
    else
        printf '%s\nyes\n' "$cert_pass"
    fi | "$VPN_BIN" \
            --interface="$VPN_IFACE" \
            --certificate="$VPN_CERT_FILE" \
            --script="$VPNC_SCRIPT" \
            "${VPN_ADDRESS}:${VPN_PORT}" &

    VPN_PID="$!"

    sleep 2

    kill -0 "$VPN_PID" 2> /dev/null \
        || die "openconnect exited during startup"

    wait_for_interface 20 \
        || {
            disconnect_vpn
            return 1
        }

    log_info "VPN connected successfully"

    return 0
}

setup_docker_user() {
    local target
    local comment

    nft list chain ip filter DOCKER-USER &> /dev/null || return 0

    for target in saddr daddr; do
        comment="oc-vpn-${target}-${OC_IPV4_CIDR}"

        nft list chain ip filter DOCKER-USER 2> /dev/null \
            | grep -qF "comment \"${comment}\"" \
            || nft add rule ip filter DOCKER-USER \
                ip "$target" "$OC_IPV4_CIDR" \
                counter accept \
                comment "$comment"
    done
}

cleanup_docker_user() {
    local target
    local comment

    nft list chain ip filter DOCKER-USER &> /dev/null || return 0

    for target in saddr daddr; do
        comment="oc-vpn-${target}-${OC_IPV4_CIDR}"

        nft -a list chain ip filter DOCKER-USER 2> /dev/null \
            | awk -v c="comment \"${comment}\"" '
                $0 ~ c {
                    for (i = 1; i <= NF; i++)
                        if ($i == "handle") print $(i + 1)
                }
            ' |
            while read -r handle; do
                nft delete rule ip filter DOCKER-USER handle "$handle" &> /dev/null || true
            done
    done
}

setup_routes() {
    mkdir -p /etc/iproute2/rt_tables.d

    grep -qsE '^430[[:space:]]+oc_vpn$' \
        /etc/iproute2/rt_tables.d/oc.conf \
        || echo "430 oc_vpn" >> /etc/iproute2/rt_tables.d/oc.conf

    ip route replace default \
        dev "$VPN_IFACE" \
        table 430 \
        metric 100

    if is_true "${OC_SPLIT_ENABLE:-false}"; then
        grep -qsE '^431[[:space:]]+oc_split$' \
            /etc/iproute2/rt_tables.d/oc.conf \
            || echo "431 oc_split" >> /etc/iproute2/rt_tables.d/oc.conf

        ip rule add fwmark 0x1 table 431 priority 99 \
            2> /dev/null || true

        ip route replace default \
            dev "$VPN_IFACE" \
            table 431 \
            metric 99
    else
        setup_docker_user
    fi

    log_info "Routing configured"
}

cleanup_routes() {
    ip route del default \
        dev "$VPN_IFACE" \
        table 430 \
        2> /dev/null || true

    if ! is_true "${OC_SPLIT_ENABLE:-false}"; then
        cleanup_docker_user
    fi
}

health_check() {
    ip link show "$VPN_IFACE" &> /dev/null \
        || return 1

    timeout 5 ping \
        -I "$VPN_IFACE" \
        -c 1 \
        -W 3 \
        "$VPN_CHECK_HOST" \
        &> /dev/null
}

reconnect() {
    disconnect_vpn

    if connect_vpn; then
        setup_routes

        if health_check; then
            log_info "VPN reconnect successful"
            return 0
        fi
    fi

    log_warn "Switching to next VPN profile"

    next_vpn_profile || return 1

    disconnect_vpn

    connect_vpn || return 1

    setup_routes

    health_check || return 1

    log_info "VPN failover successful"

    return 0
}

monitor() {
    local failures=0
    local failed_state=0

    while true; do
        if health_check; then
            if (( failed_state )); then
                log_info "VPN connectivity restored"
            fi

            failures=0
            failed_state=0

        else
            (( ++failures ))

            log_warn \
                "Health check failed (${failures}/${CHECK_THRESHOLD})"

            if (( failures >= CHECK_THRESHOLD )); then
                failed_state=1

                reconnect || \
                    log_error "Reconnect attempt failed"

                failures=0
            fi
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main() {
    setup_lock

    check_runtime

    wait_for_ocserv_port

    load_vpn_profile

    connect_vpn \
        || die "Initial VPN connection failed"

    setup_routes

    monitor
}

main "$@"
