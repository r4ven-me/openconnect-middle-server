#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="otpsender"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

# TODO: kept for a future LDAP/PAM MFA flow. The active OTP path uses
# ocserv native plain[passwd=...,otp=...] and ocuser2fa provisioning.
readonly REQUIRED_VARS=(
    OC_OTP_ENABLE
    OC_WORK_DIR
    OC_SECRETS_DIR
    OC_SCRIPTS_DIR
    OC_OTP_SEND_BY_EMAIL
    OC_OTP_SEND_BY_TELEGRAM
    PAM_USER
)

for var in "${REQUIRED_VARS[@]}"; do
    [[ -n "${!var:-}" ]] || exit 0
done

is_true "$OC_OTP_ENABLE" || exit 0

readonly PAM_LOG="${OC_WORK_DIR}/pam.log"
readonly OATH_FILE="${OC_SECRETS_DIR}/users.oath"
readonly TG_USERS_FILE="${OC_SCRIPTS_DIR}/tg_users.txt"
readonly MSMTPRC="${OC_SCRIPTS_DIR}/msmtprc"

otp_log() {
    local file="$PAM_LOG"
    local level="${1:-INFO}"
    shift 1 || true

    mkdir -p "$(dirname -- "$file")"
    printf '[%s] - [%s] - [%s] %s\n' \
        "$OC_SCRIPT_NAME" \
        "$level" \
        "$(date '+%F %T')" \
        "$*" >> "$file"
}

get_user_secret() {
    awk -v user="$PAM_USER" '$2 == user { print $4; exit }' "$OATH_FILE"
}

generate_totp() {
    local secret="$1"

    oathtool \
        --totp=SHA1 \
        --time-step-size=30 \
        --digits=6 \
        "$secret"
}

send_by_email() {
    local email_regex='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    local token="$1"

    [[ "$PAM_USER" =~ $email_regex ]] || return 0
    [[ -f "$MSMTPRC" ]] || return 0
    has_command msmtp || return 0

    {
        printf 'Subject: TOTP token for OpenConnect\n'
        printf '\n'
        printf '%s\n' "$token"
    } | msmtp --file="$MSMTPRC" "$PAM_USER" \
        && otp_log INFO "TOTP token sent to ${PAM_USER} via email" \
        || otp_log WARNING "Failed to send TOTP token to ${PAM_USER} via email"
}

send_by_telegram() {
    local tg_regex='^[A-Za-z][A-Za-z0-9_]{4,31}$'
    local token="$1"
    local chat_id=""
    local response=""
    local message="TOTP token for OpenConnect: ${token}"

    [[ "$PAM_USER" =~ $tg_regex ]] || return 0
    [[ -n "${OC_OTP_TG_TOKEN:-}" ]] || return 0
    has_command curl || return 0
    has_command jq || return 0

    touch "$TG_USERS_FILE"
    chmod 600 "$TG_USERS_FILE"

    chat_id="$(awk -v user="$PAM_USER" '$2 == user { print $1; exit }' "$TG_USERS_FILE")"

    if [[ -z "$chat_id" ]]; then
        response="$(curl -fsS "https://api.telegram.org/bot${OC_OTP_TG_TOKEN}/getUpdates")" || {
            otp_log WARNING "Unable to get Telegram updates"
            return 0
        }

        chat_id="$(
            jq -r --arg user "$PAM_USER" \
                '.result[] | select(.message.from.username == $user) | .message.chat.id' \
                <<< "$response" \
                | head -n1
        )"

        if [[ -z "$chat_id" || "$chat_id" == "null" ]]; then
            otp_log WARNING "Telegram user not found or has not interacted with bot: $PAM_USER"
            return 0
        fi

        printf '%s %s\n' "$chat_id" "$PAM_USER" >> "$TG_USERS_FILE"
    fi

    curl -fsS -X POST \
        "https://api.telegram.org/bot${OC_OTP_TG_TOKEN}/sendMessage" \
        -d "chat_id=${chat_id}" \
        --data-urlencode "text=${message}" \
        >/dev/null 2>> "$PAM_LOG" \
        && otp_log INFO "TOTP token sent to ${PAM_USER} via Telegram" \
        || otp_log WARNING "Failed to send TOTP token to ${PAM_USER} via Telegram"
}

main() {
    touch "$PAM_LOG"
    otp_log INFO "PAM user ${PAM_USER} is trying to connect to ocserv"

    [[ -f "$OATH_FILE" ]] || exit 0
    has_command oathtool || exit 0

    local secret
    local token

    secret="$(get_user_secret)"

    if [[ -z "$secret" ]]; then
        otp_log WARNING "No OTP secret found for PAM user ${PAM_USER}"
        exit 0
    fi

    token="$(generate_totp "$secret")"

    if is_true "$OC_OTP_SEND_BY_EMAIL"; then
        send_by_email "$token" &
    fi

    if is_true "$OC_OTP_SEND_BY_TELEGRAM"; then
        send_by_telegram "$token" &
    fi

    wait
}

main "$@"
