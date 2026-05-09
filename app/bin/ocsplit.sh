#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="ocsplit"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

exec &> >(logging)

readonly REQUIRED_VARS=(
    OC_CLIENT_IFACE
    OC_WORK_DIR
    OC_IPV4_NET
    OC_IPV4_MASK
    OC_DNS1
    OC_DNS2
    OC_SRV_CN
)

require_vars "${REQUIRED_VARS[@]}" || exit 1
require_commands awk dnsmasq grep inotifywait ip nft occtl wc || exit 1

readonly VPN_IFACE="$OC_CLIENT_IFACE"
OC_IPV4_CIDR="$(ipv4_cidr "$OC_IPV4_NET" "$OC_IPV4_MASK")" || die "Invalid IPv4 network/netmask: ${OC_IPV4_NET}/${OC_IPV4_MASK}"
readonly OC_IPV4_CIDR
readonly ROUTES_FILE="${OC_WORK_DIR}/routes.txt"
readonly DOMAINS_FILE="${OC_WORK_DIR}/domains.txt"
readonly OLD_ROUTES_FILE="${OC_WORK_DIR}/.routes_old.txt"

DNSMASQ_PID=""
ROUTES_WATCH_PID=""
DOMAINS_WATCH_PID=""

readonly DNSMASQ_CONF="/etc/dnsmasq.conf"
readonly DNSMASQ_OC_CONF="/etc/dnsmasq.d/oc.conf"

vpn_gateway_ip() {
    local IFS=.
    local -a octets
    local value

    read -r -a octets <<< "$OC_IPV4_NET"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    value=$(( (octets[0] << 24) + (octets[1] << 16) + (octets[2] << 8) + octets[3] + 1 ))

    printf '%s.%s.%s.%s' \
        "$(( (value >> 24) & 255 ))" \
        "$(( (value >> 16) & 255 ))" \
        "$(( (value >> 8) & 255 ))" \
        "$(( value & 255 ))"
}

cleanup() {
    local rc=$?

    trap - EXIT INT TERM HUP QUIT

    for pid in "$ROUTES_WATCH_PID" "$DOMAINS_WATCH_PID" "$DNSMASQ_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2> /dev/null; then
            kill "$pid" 2> /dev/null || true
        fi
    done

    ip rule del fwmark 0x1 table 431 priority 99 \
        &> /dev/null || true

    if nft list chain ip filter DOCKER-USER &> /dev/null; then
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
    fi

    exit "$rc"
}

trap cleanup EXIT INT TERM HUP QUIT

wait_for_interface() {
    until ip link show "$VPN_IFACE" &> /dev/null; do
        log_info "Waiting for interface: $VPN_IFACE"
        sleep 5
    done
}

convert_routes() {
    local route
    local -a old_routes=()
    local -a new_routes=()

    if [[ -f "$OLD_ROUTES_FILE" ]]; then
        mapfile -t old_routes < "$OLD_ROUTES_FILE"

        for route in "${old_routes[@]}"; do
            ip route del "$route" dev "$VPN_IFACE" \
                &> /dev/null || true
        done
    fi

    [[ -f "$ROUTES_FILE" ]] || return 0

    mapfile -t new_routes < "$ROUTES_FILE"

    for route in "${new_routes[@]}"; do
        route="$(trim "$route")"

        [[ -z "$route" || "$route" =~ ^# ]] && continue

        ip route replace "$route" dev "$VPN_IFACE" \
            &> /dev/null || true
    done

    cp -f "$ROUTES_FILE" "$OLD_ROUTES_FILE"

    log_info "Updated routes (${#new_routes[@]})"
}

watch_routes() {
    while true; do
        touch "$ROUTES_FILE"
        convert_routes

        inotifywait \
            -qq \
            -e close_write \
            -e modify \
            -e attrib \
            -e move_self \
            -e delete_self \
            "$ROUTES_FILE" || true

        sleep 0.2
    done
}

convert_domains() {
    local domain
    local tmp

    tmp="$(mktemp)"

    [[ -f "$DOMAINS_FILE" ]] || touch "$DOMAINS_FILE"

    while IFS= read -r domain; do
        domain="$(trim "$domain")"

        [[ -z "$domain" || "$domain" =~ ^# ]] && continue

        printf 'nftset=/%s/4#ip#oc_nat#oc_set\n' \
            "$domain" >> "$tmp"

    done < "$DOMAINS_FILE"

    mv -f "$tmp" "$DNSMASQ_OC_CONF"

    log_info \
        "Updated domains ($(wc -l < "$DNSMASQ_OC_CONF"))"
}

reload_dnsmasq() {
    if [[ -f /var/run/dnsmasq.pid ]]; then
        kill -HUP "$(< /var/run/dnsmasq.pid)" \
            &> /dev/null || true
    fi
}

watch_domains() {
    while true; do
        touch "$DOMAINS_FILE"
        convert_domains
        reload_dnsmasq

        inotifywait \
            -qq \
            -e close_write \
            -e modify \
            -e attrib \
            -e move_self \
            -e delete_self \
            "$DOMAINS_FILE" || true

        sleep 0.2
    done
}

setup_routing_tables() {
    mkdir -p /etc/iproute2/rt_tables.d

    grep -qsE '^431[[:space:]]+oc_split$' \
        /etc/iproute2/rt_tables.d/oc.conf \
        || echo "431 oc_split" >> /etc/iproute2/rt_tables.d/oc.conf
}

configure_dns() {
    local dns_ip

    dns_ip="$(vpn_gateway_ip)" \
        || die "Unable to calculate ocserv DNS address from $OC_IPV4_NET"

    {
        printf 'listen-address=%s\n' "$dns_ip"
        printf 'conf-dir=/etc/dnsmasq.d\n'
        printf 'server=%s\n' "$OC_DNS1"
        printf 'server=%s\n' "$OC_DNS2"
    } > "$DNSMASQ_CONF"

    sed -i -E '/^[[:space:]]*dns[[:space:]]*=/d' "$OC_WORK_DIR/ocserv.conf"
    printf '\ndns = %s\n' "$dns_ip" >> "$OC_WORK_DIR/ocserv.conf"

    occtl reload &> /dev/null || true

    log_info "DNS configured ($dns_ip)"
}

setup_nftables() {
    for chain in PREROUTING OUTPUT; do
        nft list chain ip oc_nat "$chain" 2> /dev/null \
            | grep -q 'oc_set' \
            || nft add rule ip oc_nat "$chain" \
                ip daddr @oc_set \
                ct mark set 0x1 \
                meta mark set ct mark
    done

    nft list chain ip oc_nat POSTROUTING 2> /dev/null \
        | grep -q 'meta mark 0x00000001' \
        || nft add rule ip oc_nat POSTROUTING \
            meta mark 0x1 \
            oifname "$VPN_IFACE" \
            masquerade

    for target in saddr daddr; do
        nft list chain ip oc_nat FORWARD 2> /dev/null \
            | grep -q "$target ${OC_IPV4_CIDR} accept" \
            || nft add rule ip oc_nat FORWARD \
                ip "$target" "${OC_IPV4_CIDR}" accept
    done

    if nft list chain ip filter DOCKER-USER &>/dev/null; then
        for target in saddr daddr; do
            comment="oc-vpn-${target}-${OC_IPV4_CIDR}"

            nft list chain ip filter DOCKER-USER 2> /dev/null \
                | grep -qF "comment \"${comment}\"" \
                || nft add rule ip filter DOCKER-USER \
                    ip "$target" "$OC_IPV4_CIDR" \
                    counter accept \
                    comment "$comment"
        done
    fi

    log_info "nftables configured"
}

setup_policy_routing() {
    ip rule add fwmark 0x1 table 431 priority 99 \
        2> /dev/null || true

    ip route replace \
        default dev "$VPN_IFACE" table 431 metric 99

    log_info "Policy routing configured"
}

configure_dns_tunnel() {
    local dns

    if is_true "${OC_SPLIT_TUNNEL_DNS:-false}"; then
        log_info "Enabling DNS split tunneling"

        for dns in "$OC_DNS1" "$OC_DNS2"; do
            [[ -n "$dns" ]] || continue

            ip route replace \
                "$dns" dev "$VPN_IFACE" \
                &> /dev/null || true
        done
    else
        log_info "DNS split tunneling disabled"

        for dns in "$OC_DNS1" "$OC_DNS2"; do
            [[ -n "$dns" ]] || continue

            ip route del \
                "$dns" dev "$VPN_IFACE" \
                &> /dev/null || true
        done
    fi
}

main() {
    wait_for_interface

    setup_routing_tables

    configure_dns

    setup_nftables

    setup_policy_routing

    configure_dns_tunnel

    log_info "Watching routes file..."
    watch_routes &
    ROUTES_WATCH_PID="$!"

    log_info "Watching domains file..."
    watch_domains &
    DOMAINS_WATCH_PID="$!"

    sleep 1

    log_info "Starting dnsmasq..."

    dnsmasq \
        --conf-file="$DNSMASQ_CONF" \
        --bind-dynamic \
        --port=53 \
        --no-resolv \
        --local-service \
        --domain="$OC_SRV_CN" \
        --keep-in-foreground \
        --log-facility=- &
    DNSMASQ_PID="$!"

    wait "$DNSMASQ_PID"
}

main "$@"
