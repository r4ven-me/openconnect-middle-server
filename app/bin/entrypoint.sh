#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="entrypoint"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

exec 3>&1 4>&2
exec &> >(logging)

require_root
require_commands certtool envsubst nft cmp cp chmod grep ln mkdir readlink sed touch || exit 1

readonly BASIC_VARS=(
    OC_WORK_DIR
    OC_CONF_DIR
    OC_BIN_DIR
    OC_DOC_DIR
    OC_SSL_DIR
    OC_CERTS_DIR
    OC_SECRETS_DIR
    OC_SCRIPTS_DIR
    OC_SRV_PORT
    OC_SRV_CN
    OC_SRV_CA
    OC_IPV4_NET
    OC_IPV4_MASK
    OC_DNS1
    OC_DNS2
    OC_CAMOUFLAGE_ENABLE
    OC_CAMOUFLAGE_SECRET
    OC_CAMOUFLAGE_REALM
    OC_OTP_ENABLE
    OC_CLIENT_ENABLE
    OC_SPLIT_ENABLE
)

readonly OTP_VARS=(
    OC_OTP_SEND_BY_EMAIL
    OC_OTP_SEND_BY_TELEGRAM
)

readonly MSMTP_VARS=(
    OC_OTP_MSMTP_HOST
    OC_OTP_MSMTP_PORT
    OC_OTP_MSMTP_USER
    OC_OTP_MSMTP_PASSWORD
    OC_OTP_MSMTP_FROM
)

readonly OCCLIENT_VARS=(
    OC_CLIENT_IFACE
    OC_CLIENT_CHECK_INTERVAL
    OC_CLIENT_CHECK_THRESHOLD
    OC_CLIENT_COUNT
)

readonly OCSPLIT_VARS=(
    OC_CLIENT_IFACE
    OC_SPLIT_TUNNEL_DNS
)


validate_client_profiles() {
    local idx
    local var
    local env_name
    local configured_idx
    local -a profile_vars=(
        SSL_FLAG
        SERVER
        SERVER_PORT
        CERT_FILE
        CERT_PASS
        CHECK_HOST
    )

    require_positive_int OC_CLIENT_COUNT \
        || die "Invalid OpenConnect client profile count"

    for (( idx = 0; idx < OC_CLIENT_COUNT; idx++ )); do
        for var in "${profile_vars[@]}"; do
            require_vars "OC_CLIENT_${idx}_${var}" \
                || die "Missing required OpenConnect client profile variable for index ${idx}"
        done
    done

    while IFS= read -r env_name; do
        if [[ "$env_name" =~ ^OC_CLIENT_([0-9]+)_ ]]; then
            configured_idx="${BASH_REMATCH[1]}"

            if (( configured_idx >= OC_CLIENT_COUNT )); then
                die "OpenConnect client profile [${configured_idx}] is configured, but OC_CLIENT_COUNT=${OC_CLIENT_COUNT}; set OC_CLIENT_COUNT at least to $(( configured_idx + 1 ))"
            fi
        fi
    done < <(compgen -A variable OC_CLIENT_)
}

validate_environment() {
    require_vars "${BASIC_VARS[@]}" || die "Missing required basic variables"

    if is_true "$OC_OTP_ENABLE"; then
        require_vars "${OTP_VARS[@]}" || die "Missing required OTP variables"

        if is_true "$OC_OTP_SEND_BY_EMAIL"; then
            require_vars "${MSMTP_VARS[@]}" || die "Missing required MSMTP variables"
        fi

        if is_true "$OC_OTP_SEND_BY_TELEGRAM"; then
            require_vars OC_OTP_TG_TOKEN || die "Missing required Telegram variables"
        fi
    fi

    if is_true "$OC_CLIENT_ENABLE"; then
        require_vars "${OCCLIENT_VARS[@]}" || die "Missing required OpenConnect client variables"
        validate_client_profiles
    fi

    if is_true "$OC_SPLIT_ENABLE"; then
        is_true "$OC_CLIENT_ENABLE" || die "OC_SPLIT_ENABLE requires OC_CLIENT_ENABLE=true"
        require_vars "${OCSPLIT_VARS[@]}" || die "Missing required split-tunnel variables"
    fi
}

ensure_directories() {
    mkdir -p \
        "${OC_SSL_DIR}/live/${OC_SRV_CN}" \
        "$OC_CERTS_DIR" \
        "$OC_SECRETS_DIR" \
        "$OC_SCRIPTS_DIR" \
        "${OC_WORK_DIR}/config-per-user"
}

install_runtime_files() {
    copy_once "$OC_DOC_DIR" "${OC_WORK_DIR}/doc"

    render_template_once "${OC_CONF_DIR}/ocserv.conf" "${OC_WORK_DIR}/ocserv.conf"
    render_template_once "${OC_CONF_DIR}/ca.tmpl" "${OC_CERTS_DIR}/ca.tmpl"
    render_template_once "${OC_CONF_DIR}/users.cfg" "${OC_CERTS_DIR}/users.cfg"
    render_template_once "${OC_CONF_DIR}/server.tmpl" "${OC_SSL_DIR}/server.tmpl"
    render_template_once "${OC_CONF_DIR}/crl.tmpl" "${OC_CERTS_DIR}/crl.tmpl"

    install_file "${OC_CONF_DIR}/ocserv.pam" "/etc/pam.d/ocserv"

    install_file "${OC_BIN_DIR}/common.sh" "${OC_SCRIPTS_DIR}/common.sh"
    install_file "${OC_BIN_DIR}/ocserv.sh" "${OC_SCRIPTS_DIR}/ocserv.sh"
    install_file "${OC_BIN_DIR}/connect.sh" "${OC_SCRIPTS_DIR}/connect.sh"
    install_file "${OC_BIN_DIR}/disconnect.sh" "${OC_SCRIPTS_DIR}/disconnect.sh"
    install_file "${OC_BIN_DIR}/occlient.sh" "${OC_SCRIPTS_DIR}/occlient.sh"
    install_file "${OC_BIN_DIR}/ocsplit.sh" "${OC_SCRIPTS_DIR}/ocsplit.sh"
    install_file "${OC_BIN_DIR}/custom.sh" "${OC_SCRIPTS_DIR}/custom.sh"

    chmod +x \
        "${OC_SCRIPTS_DIR}/common.sh" \
        "${OC_SCRIPTS_DIR}/ocserv.sh" \
        "${OC_SCRIPTS_DIR}/connect.sh" \
        "${OC_SCRIPTS_DIR}/disconnect.sh" \
        "${OC_SCRIPTS_DIR}/occlient.sh" \
        "${OC_SCRIPTS_DIR}/ocsplit.sh" \
        "${OC_SCRIPTS_DIR}/custom.sh"

    chmod 644 "/etc/pam.d/ocserv"

    # symlink_once "${OC_BIN_DIR}/ocuser.sh" "/usr/local/bin/ocuser"
    # symlink_once "${OC_BIN_DIR}/ocrevoke.sh" "/usr/local/bin/ocrevoke"
    # symlink_once "${OC_BIN_DIR}/ocuser2fa.sh" "/usr/local/bin/ocuser2fa"
    # symlink_once "${OC_BIN_DIR}/otpsender.sh" "/usr/local/bin/otpsender"
}

seed_split_files() {
    is_true "$OC_SPLIT_ENABLE" || return 0

    touch "${OC_WORK_DIR}/routes.txt" "${OC_WORK_DIR}/domains.txt"
    seed_file_from_env "${OC_SPLIT_ROUTES:-}" "${OC_WORK_DIR}/routes.txt"
    seed_file_from_env "${OC_SPLIT_DOMAINS:-}" "${OC_WORK_DIR}/domains.txt"
}

configure_msmtp() {
    is_true "$OC_OTP_ENABLE" || return 0
    is_true "$OC_OTP_SEND_BY_EMAIL" || return 0

    render_template_once "${OC_CONF_DIR}/msmtprc" "${OC_SCRIPTS_DIR}/msmtprc"
    chmod 400 "${OC_SCRIPTS_DIR}/msmtprc"
}

ensure_nftables() {
    { nft list table ip oc_nat &> /dev/null && nft flush table ip oc_nat; } \
        || nft add table ip oc_nat

    nft list set ip oc_nat oc_set &> /dev/null \
        || nft add set ip oc_nat oc_set \
            '{ type ipv4_addr; flags timeout; timeout 86400s; }'

    nft list chain ip oc_nat PREROUTING &> /dev/null \
        || nft add chain ip oc_nat PREROUTING \
            '{ type filter hook prerouting priority -101; policy accept; }'

    nft list chain ip oc_nat FORWARD &> /dev/null \
        || nft add chain ip oc_nat FORWARD \
            '{ type filter hook forward priority -1; policy accept; }'

    nft list chain ip oc_nat OUTPUT &> /dev/null \
        || nft add chain ip oc_nat OUTPUT \
            '{ type filter hook output priority -201; policy accept; }'

    nft list chain ip oc_nat POSTROUTING &> /dev/null \
        || nft add chain ip oc_nat POSTROUTING \
            '{ type nat hook postrouting priority 99; policy accept; }'

    log_info "nftables base objects are ready"
}

ensure_docker_user_rules() {
    is_true "$OC_CLIENT_ENABLE" && return 0
    is_true "$OC_SPLIT_ENABLE" && return 0

    nft list chain ip filter DOCKER-USER &> /dev/null || {
        log_warn "DOCKER-USER chain not found; skipping Docker forwarding rules"
        return 0
    }

    local cidr
    local target
    local comment

    cidr="$(ipv4_cidr "$OC_IPV4_NET" "$OC_IPV4_MASK")" \
        || die "Invalid IPv4 network/netmask: ${OC_IPV4_NET}/${OC_IPV4_MASK}"

    for target in saddr daddr; do
        comment="oc-vpn-${target}-${cidr}"

        nft list chain ip filter DOCKER-USER 2> /dev/null \
            | grep -qF "comment \"${comment}\"" \
            || nft add rule ip filter DOCKER-USER \
                ip "$target" "$cidr" \
                counter accept \
                comment "$comment"
    done

    log_info "DOCKER-USER rules are ready for ${cidr}"
}

generate_pki() {
    if [[ ! -f "${OC_CERTS_DIR}/ca-key.pem" ]] \
        || [[ ! -f "${OC_CERTS_DIR}/ca-cert.pem" ]]
    then
        certtool --generate-privkey --outfile "${OC_CERTS_DIR}/ca-key.pem"
        certtool \
            --generate-self-signed \
            --load-privkey "${OC_CERTS_DIR}/ca-key.pem" \
            --template "${OC_CERTS_DIR}/ca.tmpl" \
            --outfile "${OC_CERTS_DIR}/ca-cert.pem"
        chmod 600 "${OC_CERTS_DIR}/ca-key.pem"
        log_info "Generated CA certificate"
    fi

    if [[ ! -f "${OC_SSL_DIR}/live/${OC_SRV_CN}/privkey.pem" ]] \
        || [[ ! -f "${OC_SSL_DIR}/live/${OC_SRV_CN}/fullchain.pem" ]]
    then
        certtool --generate-privkey --outfile "${OC_SSL_DIR}/live/${OC_SRV_CN}/privkey.pem"
        certtool \
            --generate-certificate \
            --load-privkey "${OC_SSL_DIR}/live/${OC_SRV_CN}/privkey.pem" \
            --load-ca-certificate "${OC_CERTS_DIR}/ca-cert.pem" \
            --load-ca-privkey "${OC_CERTS_DIR}/ca-key.pem" \
            --template "${OC_SSL_DIR}/server.tmpl" \
            --outfile "${OC_SSL_DIR}/live/${OC_SRV_CN}/fullchain.pem"
        chmod 600 "${OC_SSL_DIR}/live/${OC_SRV_CN}/privkey.pem"
        log_info "Generated server certificate"
    fi

    if [[ ! -f "${OC_CERTS_DIR}/crl.pem" ]]; then
        certtool \
            --generate-crl \
            --load-ca-privkey "${OC_CERTS_DIR}/ca-key.pem" \
            --load-ca-certificate "${OC_CERTS_DIR}/ca-cert.pem" \
            --template "${OC_CERTS_DIR}/crl.tmpl" \
            --outfile "${OC_CERTS_DIR}/crl.pem"
        log_info "Generated CRL"
    fi
}

main() {
    validate_environment
    ensure_directories
    install_runtime_files
    seed_split_files
    configure_msmtp
    ensure_nftables
    ensure_docker_user_rules
    generate_pki

    log_info "Initialization completed successfully"
    exec 1>&3 2>&4 "$@"
}

main "$@"
