#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="ocuser2fa"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"


usage() {
    printf 'Usage: %s <user_id>\n' "$(basename -- "$0")" >&2
}

readonly REQUIRED_VARS=(
    OC_OTP_ENABLE
    OC_SECRETS_DIR
    OC_WORK_DIR
    OC_SRV_CA
    OC_OTP_SEND_BY_EMAIL
    OC_OTP_SEND_BY_TELEGRAM
)

require_vars "${REQUIRED_VARS[@]}" || exit 1

is_true "$OC_OTP_ENABLE" || die "OC_OTP_ENABLE is not true"

[[ $# -eq 1 ]] || {
    usage
    exit 1
}

readonly USER_ID="$1"

is_valid_name "$USER_ID" \
    || die "Invalid user_id: $USER_ID"

readonly OATH_FILE="${OC_SECRETS_DIR}/users.oath"
readonly PAM_LOG="${OC_WORK_DIR}/pam.log"
readonly QR_FILE="${OC_SECRETS_DIR}/otp_${USER_ID}.png"
readonly LOCK_FILE="${OC_SECRETS_DIR}/.ocuser2fa.lock"

require_commands base32 qrencode xxd flock || exit 1

if is_true "$OC_OTP_SEND_BY_EMAIL"; then
    require_commands msmtp base64 || exit 1
    : "${OC_SCRIPTS_DIR:?Missing OC_SCRIPTS_DIR}"
fi

if is_true "$OC_OTP_SEND_BY_TELEGRAM"; then
    require_commands curl jq || exit 1
    : "${OC_OTP_TG_TOKEN:?Missing OC_OTP_TG_TOKEN}"
    : "${OC_SCRIPTS_DIR:?Missing OC_SCRIPTS_DIR}"
fi

mkdir -p "$OC_SECRETS_DIR" "$OC_WORK_DIR"

touch "$OATH_FILE"
chmod 600 "$OATH_FILE"

exec {LOCK_FD}>"$LOCK_FILE"
flock -x "$LOCK_FD"

user_exists() {
    awk -v user="$USER_ID" '$2 == user { found = 1 } END { exit !found }' "$OATH_FILE"
}

generate_secret_hex() {
    head -c 20 /dev/urandom | xxd -p -c 256
}

hex_to_base32() {
    local hex="$1"

    printf '%s' "$hex" \
        | xxd -r -p \
        | base32 \
        | tr -d '=\n'
}

urlencode() {
    local input="$1"
    local i char

    for (( i = 0; i < ${#input}; i++ )); do
        char="${input:i:1}"

        case "$char" in
            [a-zA-Z0-9.~_-])
                printf '%s' "$char"
                ;;
            *)
                printf '%%%02X' "'$char"
                ;;
        esac
    done
}

send_qr_by_email() {
    local email_regex='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    local msmtprc="${OC_SCRIPTS_DIR}/msmtprc"

    [[ "$USER_ID" =~ $email_regex ]] || return 0
    [[ -f "$msmtprc" ]] || die "msmtp config not found: $msmtprc"

    {
        printf 'Subject: TOTP QR code for OpenConnect auth\n'
        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: multipart/mixed; boundary="oc-boundary"\n'
        printf '\n'
        printf -- '--oc-boundary\n'
        printf 'Content-Type: text/plain; charset=UTF-8\n'
        printf '\n'
        printf 'TOTP secret for OpenConnect (base32):\n%s\n' "$OTP_SECRET_BASE32"
        printf '\n'
        printf -- '--oc-boundary\n'
        printf 'Content-Type: image/png; name="otp.png"\n'
        printf 'Content-Transfer-Encoding: base64\n'
        printf 'Content-Disposition: attachment; filename="otp.png"\n'
        printf '\n'
        base64 "$QR_FILE"
        printf '\n--oc-boundary--\n'
    } | msmtp --file="$msmtprc" "$USER_ID"

    log_info "TOTP QR sent to ${USER_ID} via email"
}

send_qr_by_telegram() {
    local tg_regex='^[A-Za-z][A-Za-z0-9_]{4,31}$'
    local tg_users_file="${OC_SCRIPTS_DIR}/tg_users.txt"
    local tg_chat_id=""
    local tg_response=""
    local tg_message

    [[ "$USER_ID" =~ $tg_regex ]] || return 0

    touch "$tg_users_file"
    chmod 600 "$tg_users_file"

    tg_chat_id="$(
        awk -v user="$USER_ID" '$2 == user { print $1; exit }' "$tg_users_file"
    )"

    if [[ -z "$tg_chat_id" ]]; then
        tg_response="$(
            curl -fsS \
                "https://api.telegram.org/bot${OC_OTP_TG_TOKEN}/getUpdates"
        )" || {
            log_warn "Unable to get Telegram updates"
            return 0
        }

        tg_chat_id="$(
            jq -r --arg user "$USER_ID" \
                '.result[]
                 | select(.message.from.username == $user)
                 | .message.chat.id' \
                <<< "$tg_response" \
                | head -n1
        )"

        if [[ -z "$tg_chat_id" || "$tg_chat_id" == "null" ]]; then
            log_warn "Telegram user not found or has not interacted with bot: $USER_ID"
            return 0
        fi

        printf '%s %s\n' "$tg_chat_id" "$USER_ID" >> "$tg_users_file"
    fi

    tg_message=$(
        printf 'TOTP secret for OpenConnect (base32):\n%s' "$OTP_SECRET_BASE32"
    )

    curl -fsS -X POST \
        "https://api.telegram.org/bot${OC_OTP_TG_TOKEN}/sendPhoto" \
        -F "chat_id=${tg_chat_id}" \
        -F "photo=@${QR_FILE}" \
        -F "caption=${tg_message}" \
        >/dev/null 2>> "$PAM_LOG" || {
            log_warn "Failed to send Telegram QR to $USER_ID"
            return 0
        }

    log_info "TOTP QR sent to ${USER_ID} via Telegram"
}

if user_exists; then
    die "OTP token already exists for user: $USER_ID"
fi

OTP_SECRET="$(generate_secret_hex)"
OTP_SECRET_BASE32="$(hex_to_base32 "$OTP_SECRET")"

OTP_SECRET_QR="$(
    printf 'otpauth://totp/%s?secret=%s&issuer=%s&algorithm=SHA1&digits=6&period=30' \
        "$(urlencode "$USER_ID")" \
        "$OTP_SECRET_BASE32" \
        "$(urlencode "$OC_SRV_CA")"
)"

printf 'HOTP/T30 %s - %s\n' "$USER_ID" "$OTP_SECRET" >> "$OATH_FILE"

qrencode -t ANSIUTF8 "$OTP_SECRET_QR"
qrencode -s 10 -o "$QR_FILE" "$OTP_SECRET_QR"
chmod 600 "$QR_FILE"

log_info "OTP secret for ${USER_ID}: ${OTP_SECRET}"
log_info "OTP secret base32 for ${USER_ID}: ${OTP_SECRET_BASE32}"
log_info "QR image saved: $QR_FILE"

if is_true "$OC_OTP_SEND_BY_EMAIL"; then
    send_qr_by_email
fi

if is_true "$OC_OTP_SEND_BY_TELEGRAM"; then
    send_qr_by_telegram
fi
