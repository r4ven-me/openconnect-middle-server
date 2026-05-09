#!/usr/bin/env bash

set -Eeuo pipefail

readonly OC_SCRIPT_NAME="supervisord"
source "${OC_BIN_DIR:-/opt/oc/bin}/common.sh"

exec &> >(logging)

require_vars OC_CONF_DIR || exit 1

readonly SUPERVISORD_TEMPLATE="${OC_CONF_DIR}/supervisord.conf"
readonly SUPERVISORD_CONF="/etc/supervisord.conf"

require_commands supervisord envsubst || exit 1

[[ -f "$SUPERVISORD_TEMPLATE" ]] \
    || die "Template not found: $SUPERVISORD_TEMPLATE"

envsubst < "$SUPERVISORD_TEMPLATE" > "$SUPERVISORD_CONF"

log_info "Starting supervisord"

exec supervisord \
    --configuration "$SUPERVISORD_CONF" \
    --nodaemon
