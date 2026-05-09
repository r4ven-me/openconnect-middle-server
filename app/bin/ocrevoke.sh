#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="ocrevoke"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"


usage() {
    cat <<'EOF'
Usage:
  ocrevoke <user>   Revoke user certificate
  ocrevoke RELOAD   Regenerate CRL from revoked.pem
  ocrevoke RESET    Reset all revoked certificates
  ocrevoke HELP     Print this help
EOF
}

readonly REQUIRED_VARS=(
    OC_CERTS_DIR
)

require_vars "${REQUIRED_VARS[@]}" || exit 1

readonly CA_KEY="${OC_CERTS_DIR}/ca-key.pem"
readonly CA_CERT="${OC_CERTS_DIR}/ca-cert.pem"
readonly CRL_TMPL="${OC_CERTS_DIR}/crl.tmpl"
readonly CRL_FILE="${OC_CERTS_DIR}/crl.pem"
readonly REVOKED_FILE="${OC_CERTS_DIR}/revoked.pem"
readonly REVOKED_USERS_FILE="${OC_CERTS_DIR}/revoked.users"
readonly LOCK_FILE="${OC_CERTS_DIR}/.ocrevoke.lock"

require_commands certtool occtl || exit 1

require_files "$CA_KEY" "$CA_CERT" "$CRL_TMPL" || exit 1

exec {LOCK_FD}>"$LOCK_FILE"
flock -x "$LOCK_FD"

generate_crl() {
    local tmp

    tmp="$(mktemp "${OC_CERTS_DIR}/crl.pem.XXXXXX")"

    if [[ -s "$REVOKED_FILE" ]]; then
        certtool \
            --generate-crl \
            --load-ca-privkey "$CA_KEY" \
            --load-ca-certificate "$CA_CERT" \
            --load-certificate "$REVOKED_FILE" \
            --template "$CRL_TMPL" \
            --outfile "$tmp"
    else
        certtool \
            --generate-crl \
            --load-ca-privkey "$CA_KEY" \
            --load-ca-certificate "$CA_CERT" \
            --template "$CRL_TMPL" \
            --outfile "$tmp"
    fi

    mv -f "$tmp" "$CRL_FILE"
}

reload_ocserv() {
    occtl reload &> /dev/null || true
}

reset_revokes() {
    : > "$REVOKED_FILE"
    : > "$REVOKED_USERS_FILE"
    generate_crl
    reload_ocserv
    log_info "Revocation list reset"
}

reload_crl() {
    generate_crl
    reload_ocserv
    log_info "CRL regenerated"
}

revoke_user() {
    local user="$1"
    local cert_file="${OC_CERTS_DIR}/${user}-cert.pem"

    is_valid_name "$user" \
        || die "Invalid username: $user"

    [[ -f "$cert_file" ]] \
        || die "User certificate not found: $cert_file"

    touch "$REVOKED_FILE" "$REVOKED_USERS_FILE"

    if grep -qxF "$user" "$REVOKED_USERS_FILE"; then
        log_info "User certificate already listed as revoked: $user"
    else
        cat "$cert_file" >> "$REVOKED_FILE"
        printf '\n' >> "$REVOKED_FILE"
        printf '%s\n' "$user" >> "$REVOKED_USERS_FILE"
    fi

    generate_crl
    reload_ocserv

    log_info "Certificate revoked for user: $user"
}

case "${1:-}" in
    HELP|-h|--help)
        usage
        ;;
    RESET)
        reset_revokes
        ;;
    RELOAD)
        reload_crl
        ;;
    "")
        usage
        exit 1
        ;;
    *)
        [[ $# -eq 1 ]] || {
            usage
            exit 1
        }

        revoke_user "$1"
        ;;
esac
