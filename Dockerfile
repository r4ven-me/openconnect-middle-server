# https://gitlab.com/openconnect/ocserv

# ========STAGE 1: BUILD========

FROM debian:13-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_VERSION="13"
ENV DEBIAN_VERSION_ID="trixie"
ENV OCSERV_VERSION="1.4.2"

LABEL maintainer="Ivan Cherniy <kar-kar@r4ven.me>"

SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

# Keep downloaded packages between builds (Docker BuildKit cache)
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Все build-зависимости + компиляция в одном слое + cache-mounts
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=tmpfs,target=/var/log \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=tmpfs,target=/var/cache/debconf \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    set -x && \
    echo "deb http://deb.debian.org/debian ${DEBIAN_VERSION_ID} main" >> /etc/apt/sources.list && \
    apt update && \
    apt upgrade --yes && \
    apt install --yes --no-install-recommends --no-install-suggests \
        curl build-essential meson pkg-config ninja-build fakeroot devscripts \
        iputils-ping ruby-ronn openconnect libuid-wrapper \
        libnss-wrapper libsocket-wrapper gss-ntlmssp git-core make autoconf \
        libtool autopoint gettext automake nettle-dev libwrap0-dev \
        libpam0g-dev liblz4-dev libseccomp-dev libreadline-dev libtasn1-bin libnl-route-3-dev \
        libkrb5-dev liboath-dev libradcli-dev libprotobuf-c-dev libtalloc-dev libllhttp-dev \
        libhttp-parser-dev protobuf-c-compiler gperf liblockfile-bin \
        nuttcp libpam-oath libev-dev libgnutls28-dev gnutls-bin haproxy \
        yajl-tools libcurl4-gnutls-dev libcjose-dev libjansson-dev libssl-dev \
        iproute2 libpam-wrapper tcpdump libopenconnect-dev iperf3 lcov ipcalc faketime \
        freeradius libfreeradius-dev gawk jq && \
    curl -fLO https://www.infradead.org/ocserv/download/ocserv-"${OCSERV_VERSION}".tar.xz && \
    tar -xvf ./ocserv-"${OCSERV_VERSION}".tar.xz && \
    cd ./ocserv-"${OCSERV_VERSION}"/ && \
    meson setup build -Doidc-auth=enabled && \
    ninja -C build install

WORKDIR /ocserv-"${OCSERV_VERSION}"

# docker build --target builder -t ocserv-builder:tmp ./
# docker run -it --rm ocserv-builder:tmp bash

# ========STAGE 2: RUNTIME========

FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_VERSION="13"
ENV DEBIAN_VERSION_ID="trixie"
ENV OCSERV_VERSION="1.4.2"

LABEL maintainer="Ivan Cherniy <kar-kar@r4ven.me>"

STOPSIGNAL SIGTERM

# Keep downloaded packages between builds
RUN rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Все runtime-пакеты + копирование бинарников из builder в одном слое + cache-mounts
RUN --mount=type=bind,target=/src,source=./ \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=type=tmpfs,target=/var/log \
    --mount=type=tmpfs,target=/var/tmp \
    --mount=type=tmpfs,target=/var/cache/debconf \
    --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    set -x && \
    apt update && \
    apt install --yes --no-install-recommends --no-install-suggests \
        adduser \
        ssl-cert \
        libc6 \
        libcrypt1 \
        libev4t64 \
        libgnutls30t64 \
        libgssapi-krb5-2 \
        liblz4-1 \
        libmaxminddb0 \
        libnettle8t64 \
        libnl-3-200 \
        liboath0t64 \
        libpam0g \
        libreadline8t64 \
        libseccomp2 \
        libsystemd0 \
        libtasn1-6 \
        libllhttp9.2 \
        libtalloc2 \
        libradcli4 \
        libprotobuf-c1 \
        libnl-route-3-200 \
        libcurl4 \
        libcjose0 \
        libjansson4 \
        libhttp-parser2.9 \
        libwrap0 \
        procps \
        grep \
        sed \
        gettext-base \
        gnutls-bin \
        iptables \
        iproute2 \
        iputils-ping \
        less \
        ca-certificates \
        xxd \
        libpam-oath \
        oathtool \
        qrencode \
        curl \
        jq \
        msmtp \
        nftables \
        dnsmasq \
        openconnect \
        vpnc-scripts \
        inotify-tools \
        util-linux \
        supervisor && \
    apt autoremove --yes && \
    apt clean --yes && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/*

COPY --from=builder /usr/local /usr/local

# COPY --from=builder ["/ocserv-${OCSERV_VERSION}/build/src/occtl/occtl", "/usr/local/bin"]
# COPY --from=builder ["/ocserv-${OCSERV_VERSION}/build/src/ocpasswd/ocpasswd", "/usr/local/bin"]
# COPY --from=builder ["/ocserv-${OCSERV_VERSION}/build/src/ocserv", "/usr/local/sbin"]
# COPY --from=builder ["/ocserv-${OCSERV_VERSION}/build/src/ocserv-worker", "/usr/local/sbin"]
# COPY --from=builder ["/ocserv-${OCSERV_VERSION}/src/ocserv-fw-nftables", "/usr/local/libexec/ocserv-fw"]

ENV OC_CONF_DIR="/opt/oc/etc"
ENV OC_BIN_DIR="/opt/oc/bin"
ENV OC_DOC_DIR="/opt/oc/doc"
ENV OC_WORK_DIR="/etc/ocserv"
ENV OC_CERTS_DIR="${OC_WORK_DIR}/certs"
ENV OC_SSL_DIR="${OC_WORK_DIR}/ssl"
ENV OC_SECRETS_DIR="${OC_WORK_DIR}/secrets"
ENV OC_SCRIPTS_DIR="${OC_WORK_DIR}/scripts"
ENV OC_IPV4_NET="10.10.10.0"
ENV OC_IPV4_MASK="255.255.255.0"
ENV OC_DNS1="8.8.8.8"
ENV OC_DNS2="8.8.4.4"
ENV OC_SRV_PORT="443"
ENV OC_SRV_CN="localhost"
ENV OC_SRV_CA="OpenConnect CA"
ENV OC_CAMOUFLAGE_ENABLE="false"
ENV OC_CAMOUFLAGE_SECRET="secretword"
ENV OC_CAMOUFLAGE_REALM="Welcome to private service"
ENV OC_OTP_ENABLE="false"
ENV OC_OTP_SEND_BY_EMAIL="false"
ENV OC_OTP_SEND_BY_TELEGRAM="false"
ENV OC_CLIENT_ENABLE="false"
ENV OC_MAIN_IFACE=""
ENV OC_CLIENT_IFACE="tun10"
ENV OC_CLIENT_CHECK_INTERVAL="5"
ENV OC_CLIENT_CHECK_THRESHOLD="3"
ENV OC_CLIENT_COUNT="1"
ENV OC_SPLIT_ENABLE="false"
ENV OC_SPLIT_TUNNEL_DNS="false"
ENV OC_SPLIT_ROUTES=""
ENV OC_SPLIT_DOMAINS=""
ENV PATH="${OC_BIN_DIR}:${OC_SCRIPTS_DIR}:${PATH}"

COPY ./app /opt/oc

RUN ln -sfn "${OC_BIN_DIR}/ocuser.sh" "/usr/local/bin/ocuser" && \
        ln -sfn "${OC_BIN_DIR}/ocrevoke.sh" "/usr/local/bin/ocrevoke" && \
        ln -sfn "${OC_BIN_DIR}/ocuser2fa.sh" "/usr/local/bin/ocuser2fa"

WORKDIR $OC_WORK_DIR

ENTRYPOINT ["/opt/oc/bin/entrypoint.sh"]

CMD ["/opt/oc/bin/supervisord.sh"]

HEALTHCHECK --interval=5m --timeout=3s \
    CMD curl -k "https://localhost:${OC_SRV_PORT}/" || exit 1
