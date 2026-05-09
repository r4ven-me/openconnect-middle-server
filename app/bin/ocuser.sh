#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="ocuser"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"


usage() {
    cat >&2 <<'EOF'
Usage:
  ocuser <username> <common_name>
  ocuser -A <username> <common_name>

Examples:
  ocuser john "John Doe"
  ocuser -A steve "Steve Jobs"
EOF
}

readonly REQUIRED_VARS=(
    OC_SRV_CN
    OC_CERTS_DIR
    OC_SECRETS_DIR
    OC_WORK_DIR
)

require_vars "${REQUIRED_VARS[@]}" || exit 1

require_commands certtool ocpasswd flock base64 || exit 1

readonly CA_KEY="${OC_CERTS_DIR}/ca-key.pem"
readonly CA_CERT="${OC_CERTS_DIR}/ca-cert.pem"
readonly USER_TEMPLATE="${OC_CERTS_DIR}/users.cfg"
readonly OCPASSWD_FILE="${OC_WORK_DIR}/ocpasswd"
readonly LOCK_FILE="${OC_CERTS_DIR}/.ocuser.lock"

require_files "$CA_KEY" "$CA_CERT" "$USER_TEMPLATE" || exit 1

APPLE_COMPAT=false

case "$#" in
    2)
        USER_UID="$1"
        USER_CN="$2"
        ;;
    3)
        [[ "$1" == "-A" ]] || {
            usage
            exit 1
        }

        APPLE_COMPAT=true
        USER_UID="$2"
        USER_CN="$3"
        ;;
    *)
        usage
        exit 1
        ;;
esac

is_valid_name "$USER_UID" \
    || die "Invalid username: $USER_UID"

[[ -n "$USER_CN" ]] \
    || die "Common name is empty"

readonly USER_KEY="${OC_CERTS_DIR}/${USER_UID}-privkey.pem"
readonly USER_CERT="${OC_CERTS_DIR}/${USER_UID}-cert.pem"
readonly USER_P12="${OC_SECRETS_DIR}/${USER_UID}.p12"

exec {LOCK_FD}>"$LOCK_FILE"
flock -x "$LOCK_FD"

tmp_template="$(mktemp "${OC_CERTS_DIR}/users.cfg.XXXXXX")"

cleanup() {
    rm -f "${tmp_template:-}"
}

trap cleanup EXIT

sed \
    -e "s|^organization[[:space:]]*=.*|organization = ${OC_SRV_CN}|" \
    -e "s|^cn[[:space:]]*=.*|cn = ${USER_CN}|" \
    -e "s|^uid[[:space:]]*=.*|uid = ${USER_UID}|" \
    "$USER_TEMPLATE" > "$tmp_template"

password="$(
    dd if=/dev/urandom bs=64 count=1 2> /dev/null \
        | base64 \
        | tr -dc 'A-Za-z0-9'
)"
password="${password:0:60}"

[[ -n "$password" ]] || die "Failed to generate random password"

printf '%s\n' "$password" \
    | ocpasswd -c "$OCPASSWD_FILE" "$USER_UID"

certtool \
    --generate-privkey \
    --outfile "$USER_KEY"

certtool \
    --generate-certificate \
    --load-privkey "$USER_KEY" \
    --load-ca-certificate "$CA_CERT" \
    --load-ca-privkey "$CA_KEY" \
    --template "$tmp_template" \
    --outfile "$USER_CERT"

if is_true "$APPLE_COMPAT"; then
    certtool \
        --to-p12 \
        --load-certificate "$USER_CERT" \
        --load-privkey "$USER_KEY" \
        --pkcs-cipher 3des-pkcs12 \
        --hash SHA1 \
        --outder \
        --outfile "$USER_P12"
else
    certtool \
        --to-p12 \
        --load-certificate "$USER_CERT" \
        --load-privkey "$USER_KEY" \
        --pkcs-cipher aes-256 \
        --outder \
        --outfile "$USER_P12"
fi

chmod 600 "$USER_KEY" "$USER_CERT" "$USER_P12"

log_info "User certificate generated: $USER_UID"
log_info "P12 file: $USER_P12"
