#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="disconnect"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

require_vars \
    USERNAME \
    IP_REMOTE \
    STATS_BYTES_IN \
    STATS_BYTES_OUT \
    STATS_DURATION \
    OC_CLIENT_ENABLE \
    OC_SPLIT_ENABLE \
    || exit 1

delete_masquerade_rules() {
    local src_ip="$1"
    local handle

    nft -a list chain ip oc_nat POSTROUTING 2> /dev/null \
        | awk -v ip="$src_ip" '
            $0 ~ "comment \\\"ocmasq-" ip "-" {
                for (i = 1; i <= NF; i++) {
                    if ($i == "handle") print $(i + 1)
                }
            }
        ' \
        | while IFS= read -r handle; do
            [[ -n "$handle" ]] || continue
            nft delete rule ip oc_nat POSTROUTING handle "$handle" \
                &> /dev/null || true
        done
}

delete_policy_rules() {
    local src_ip="$1"

    while ip rule del from "${src_ip}/32" table 430 &> /dev/null; do
        :
    done
}

main() {
    log_info "User disconnected: username=${USERNAME}, vpn_ip=${IP_REMOTE}, bytes_in=${STATS_BYTES_IN}, bytes_out=${STATS_BYTES_OUT}, duration=${STATS_DURATION}"

    delete_masquerade_rules "$IP_REMOTE"

    if is_true "$OC_CLIENT_ENABLE" && ! is_true "$OC_SPLIT_ENABLE"; then
        delete_policy_rules "$IP_REMOTE"
    fi

    log_info "Routing/NAT cleaned: username=${USERNAME}, vpn_ip=${IP_REMOTE}"
}

main "$@"
