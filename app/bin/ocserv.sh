#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="ocserv"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

exec &> >(logging)

require_commands awk grep mktemp sed ocserv || exit 1

require_vars \
    OC_WORK_DIR \
    OC_SRV_PORT \
    OC_SSL_DIR \
    OC_SRV_CN \
    OC_CERTS_DIR \
    OC_SCRIPTS_DIR \
    OC_IPV4_NET \
    OC_IPV4_MASK \
    OC_DNS1 \
    OC_DNS2 \
    OC_CAMOUFLAGE_ENABLE \
    OC_CAMOUFLAGE_SECRET \
    OC_CAMOUFLAGE_REALM \
    OC_OTP_ENABLE \
    OC_SECRETS_DIR \
    || exit 1

readonly OCSERV_CONF="${OC_WORK_DIR}/ocserv.conf"
readonly PAM_FILE="/etc/pam.d/ocserv"
readonly OVERRIDE_START="#=============START ENV-GENERATED OVERRIDE=============#"
readonly OVERRIDE_END="#=============END ENV-GENERATED OVERRIDE=============#"

cleanup() {
    local rc=$?

    trap - EXIT INT TERM HUP QUIT

    { nft list table ip oc_nat &> /dev/null \
        && nft delete table ip oc_nat &> /dev/null; } || true

    exit "$rc"
}

trap cleanup EXIT INT TERM HUP QUIT

ocserv_uses_pam() {
    grep -Eq '^[[:space:]]*(auth|enable-auth|acct)[[:space:]]*=[[:space:]]*"?pam(\[|"|[[:space:]]|$)' "$OCSERV_CONF"
}

ocserv_uses_plain_otp() {
    grep -Eq '^[[:space:]]*auth[[:space:]]*=[[:space:]]*"?plain\[[^]]*(^|,)otp=' "$OCSERV_CONF"
}

configure_pam() {
    if ocserv_uses_pam; then
        require_files "$PAM_FILE" || die "PAM service file not installed: $PAM_FILE"
        log_info "PAM configured"

        if is_true "$OC_OTP_ENABLE"; then
            log_warn "PAM TOTP sender is disabled; TODO: design LDAP/PAM MFA integration"
        fi
    fi

    if is_true "$OC_OTP_ENABLE"; then
        if ocserv_uses_plain_otp; then
            log_info "Native ocserv plain OTP configured"
        else
            log_warn "OC_OTP_ENABLE=true, but ocserv.conf does not enable plain OTP"
        fi
    fi
}

write_ocserv_overrides() {
    local tmp
    local param
    local -a params=(
        tcp-port
        server-cert
        server-key
        ca-cert
        crl
        config-per-user
        connect-script
        disconnect-script
        default-domain
        ipv4-network
        ipv4-netmask
        dns
        camouflage
        camouflage_secret
        camouflage_realm
    )

    require_files "$OCSERV_CONF" || die "Config file not found: $OCSERV_CONF"

    tmp="$(mktemp)"
    cp "$OCSERV_CONF" "$tmp"

    sed -i -E "/^[[:space:]]*${OVERRIDE_START//=/\\=}/,/^[[:space:]]*${OVERRIDE_END//=/\\=}/d" "$tmp"

    for param in "${params[@]}"; do
        sed -i -E "/^[[:space:]]*${param}[[:space:]]*=/d" "$tmp"
    done

    cat >> "$tmp" <<EOF2

${OVERRIDE_START}
tcp-port = ${OC_SRV_PORT}
server-cert = ${OC_SSL_DIR}/live/${OC_SRV_CN}/fullchain.pem
server-key = ${OC_SSL_DIR}/live/${OC_SRV_CN}/privkey.pem
ca-cert = ${OC_CERTS_DIR}/ca-cert.pem
crl = ${OC_CERTS_DIR}/crl.pem
config-per-user = ${OC_WORK_DIR}/config-per-user/
connect-script = ${OC_SCRIPTS_DIR}/connect.sh
disconnect-script = ${OC_SCRIPTS_DIR}/disconnect.sh
default-domain = ${OC_SRV_CN}
ipv4-network = ${OC_IPV4_NET}
ipv4-netmask = ${OC_IPV4_MASK}
dns = ${OC_DNS1}
dns = ${OC_DNS2}
camouflage = ${OC_CAMOUFLAGE_ENABLE}
camouflage_secret = "${OC_CAMOUFLAGE_SECRET}"
camouflage_realm = "${OC_CAMOUFLAGE_REALM}"
${OVERRIDE_END}
EOF2

    mv -f "$tmp" "$OCSERV_CONF"
    log_info "Configuration written: $OCSERV_CONF"
}

main() {
    write_ocserv_overrides
    configure_pam

    log_info "Starting OpenConnect server"
    exec ocserv --config "$OCSERV_CONF" --foreground
}

main "$@"
