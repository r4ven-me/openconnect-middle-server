#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="connect"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

require_vars \
    USERNAME \
    IP_REAL_LOCAL \
    IP_REMOTE \
    IP_REAL \
    DEVICE \
    OC_CLIENT_ENABLE \
    OC_SPLIT_ENABLE \
    || exit 1

require_commands ip nft awk grep || exit 1

get_default_iface() {
    local iface="${OC_MAIN_IFACE:-}"

    if [[ -n "$iface" ]]; then
        printf '%s' "$iface"
        return 0
    fi

    ip -4 route show default \
        | awk '
            {
                dev = ""
                metric = 0
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev") dev = $(i + 1)
                    if ($i == "metric") metric = $(i + 1)
                }
                if (dev == "") next
                if (dev ~ /^(lo|docker|br-|veth|vnet|virbr|vmbr|tun|tap|wg|ppp|vpn|oc|cni|flannel|vxlan)/) next
                if (best == "" || metric < best_metric) {
                    best = dev
                    best_metric = metric
                }
            }
            END { if (best != "") print best }
        '
}

add_masquerade_once() {
    local src_ip="$1"
    local oif="$2"
    local comment="ocmasq-${src_ip}:${oif}"

    [[ -n "$oif" ]] || return 0

    nft list chain ip oc_nat POSTROUTING 2> /dev/null \
        | grep -qF "comment \"${comment}\"" \
        && return 0

    nft add rule ip oc_nat POSTROUTING \
        ip saddr "${src_ip}/32" \
        oifname "$oif" \
        counter masquerade \
        comment "\"$comment\""
}

add_policy_rule_once() {
    local src_ip="$1"
    local table="${2:-430}"

    ip rule show \
        | grep -qE "from ${src_ip} lookup ${table}" \
        && return 0

    ip rule add from "${src_ip}/32" table "$table"
}

main() {
    local main_iface

    main_iface="$(get_default_iface)"
    [[ -n "$main_iface" ]] || die "Unable to detect default interface"

    log_info "User connected: username=${USERNAME}, server=${IP_REAL_LOCAL}, vpn_ip=${IP_REMOTE}, remote_ip=${IP_REAL}, device=${DEVICE}"

    if is_true "$OC_CLIENT_ENABLE" \
        && [[ -n "${OC_CLIENT_IFACE:-}" ]] \
        && ip link show "$OC_CLIENT_IFACE" &> /dev/null
    then
        add_masquerade_once "$IP_REMOTE" "$OC_CLIENT_IFACE"

        if is_true "$OC_SPLIT_ENABLE"; then
            add_masquerade_once "$IP_REMOTE" "$main_iface"
        else
            add_policy_rule_once "$IP_REMOTE" 430
        fi
    else
        add_masquerade_once "$IP_REMOTE" "$main_iface"
    fi

    log_info "Routing/NAT configured: username=${USERNAME}, vpn_ip=${IP_REMOTE}"
}

main "$@"
