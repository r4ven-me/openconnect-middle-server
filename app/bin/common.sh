#!/usr/bin/env bash

# Shared helpers for OpenConnect container scripts.
# shellcheck shell=bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ -z "${OC_SCRIPT_NAME:-}" ]]; then
    OC_SCRIPT_NAME="$(basename -- "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" .sh)"
fi

# log() {
#     local level="${1:-INFO}"
#     shift || true

#     printf '[%s] - [%s] - [%s] - %s\n' \
#         "$(date '+%Y-%m-%d %H:%M:%S.%3N')" \
#         "$OC_SCRIPT_NAME" \
#         "$level"
#         "$*" >&2
# }


setup_colors() {
    export COLOR_RESET='\033[0m'
    export COLOR_RED='\033[0;31m'
    export COLOR_GREEN='\033[0;32m'
    export COLOR_YELLOW='\033[0;33m'
    export COLOR_BLUE='\033[0;34m'
    export COLOR_PURPLE='\033[0;35m'
    export COLOR_CYAN='\033[0;36m'
}

setup_colors

logging() {
    while IFS= read -r line; do
        printf '[%s] - %s\n' \
            "$OC_SCRIPT_NAME" \
            "$line"
    done
}

log_info() { printf "${COLOR_BLUE}[INFO] - %s\n${COLOR_RESET}" "$*"; }
log_warn() { printf "${COLOR_YELLOW}[WARN] - %s\n${COLOR_RESET}" "$*"; }
log_error() { printf "${COLOR_RED}[ERROR] - %s\n${COLOR_RESET}" "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

require_root() {
    (( EUID == 0 )) || die "This script must be run as root"
}

require_vars() {
    local var
    local failed=0

    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Missing environment variable: $var"
            failed=1
        fi
    done

    return "$failed"
}

has_command() {
    command -v "$1" &> /dev/null
}

require_commands() {
    local cmd
    local failed=0

    for cmd in "$@"; do
        if ! has_command "$cmd"; then
            log_error "Missing required utility: $cmd"
            failed=1
        fi
    done

    return "$failed"
}

require_files() {
    local file
    local failed=0

    for file in "$@"; do
        if [[ ! -f "$file" ]]; then
            log_error "Required file not found: $file"
            failed=1
        fi
    done

    return "$failed"
}

require_positive_int() {
    local name="$1"
    local value="${!name:-}"

    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        log_error "$name must be a positive integer"
        return 1
    }
}

require_non_negative_int() {
    local name="$1"
    local value="${!name:-}"

    [[ "$value" =~ ^[0-9]+$ ]] || {
        log_error "$name must be a non-negative integer"
        return 1
    }
}

is_true() {
    [[ "${1:-}" == "true" ]]
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_valid_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._@-]+$ ]]
}

mask_to_prefix() {
    local mask="$1"
    local IFS=.
    local -a octets
    local octet
    local prefix=0
    local seen_zero=0

    read -r -a octets <<< "$mask"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        case "$octet" in
            255)
                (( seen_zero == 0 )) || return 1
                (( prefix += 8 ))
                ;;
            254)
                (( seen_zero == 0 )) || return 1
                (( prefix += 7 ))
                seen_zero=1
                ;;
            252)
                (( seen_zero == 0 )) || return 1
                (( prefix += 6 ))
                seen_zero=1
                ;;
            248)
                (( seen_zero == 0 )) || return 1
                (( prefix += 5 ))
                seen_zero=1
                ;;
            240)
                (( seen_zero == 0 )) || return 1
                (( prefix += 4 ))
                seen_zero=1
                ;;
            224)
                (( seen_zero == 0 )) || return 1
                (( prefix += 3 ))
                seen_zero=1
                ;;
            192)
                (( seen_zero == 0 )) || return 1
                (( prefix += 2 ))
                seen_zero=1
                ;;
            128)
                (( seen_zero == 0 )) || return 1
                (( prefix += 1 ))
                seen_zero=1
                ;;
            0)
                seen_zero=1
                ;;
            *)
                return 1
                ;;
        esac
    done

    printf '%s' "$prefix"
}

ipv4_cidr() {
    local network="$1"
    local mask="$2"
    local prefix

    prefix="$(mask_to_prefix "$mask")" || return 1
    printf '%s/%s' "$network" "$prefix"
}

copy_once() {
    local src="$1"
    local dst="$2"

    if [[ ! -e "$dst" ]]; then
        cp -a "$src" "$dst"
        log_info "Copied: $dst"
    fi
}

install_file() {
    local src="$1"
    local dst="$2"

    [[ -f "$src" ]] || die "Source file not found: $src"

    # if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
    if [[ ! -f "$dst" ]]; then
        cp -a "$src" "$dst"
        log_info "Installed: $dst"
    fi
}

render_template_once() {
    local src="$1"
    local dst="$2"

    [[ -f "$src" ]] || die "Template not found: $src"

    if [[ ! -f "$dst" ]]; then
        envsubst < "$src" > "$dst"
        log_info "Generated: $dst"
    fi
}

symlink_once() {
    local src="$1"
    local dst="$2"

    if [[ ! -L "$dst" || "$(readlink -- "$dst")" != "$src" ]]; then
        ln -sfn "$src" "$dst"
        log_info "Linked: $dst -> $src"
    fi
}

seed_file_from_env() {
    local value="$1"
    local dst="$2"

    [[ -n "$value" ]] || return 0
    [[ ! -s "$dst" ]] || return 0

    printf '%s\n' "$value" \
        | sed -e '/^[[:space:]]*$/d' > "$dst"

    log_info "Seeded: $dst"
}
