# OpenConnect container

OpenConnect/ocserv container with an optional upstream OpenConnect client, split tunneling via dnsmasq+nftables, and OTP via ocpasswd.

## Quick start

```bash
cp .env.example .env
vim .env

docker compose build
docker compose up -d
```

At minimum, update these values in `.env`:

```bash
OC_SRV_CN="vpn.example.com"
OC_SRV_CA="Example CA"
OC_SRV_PORT="443"
```

If an external certificate is not mounted at `./data/ssl/live/$OC_SRV_CN/`, the entrypoint will generate an internal CA and server certificate automatically.

## Create a user

```bash
docker exec -it openconnect ocuser username "User Name"
```

For an Apple-compatible p12:

```bash
docker exec -it openconnect ocuser -A username "User Name"
```

The generated `.p12` file will appear in `./data/secrets/`.

## OTP

Enable OTP in `.env`:

```bash
OC_OTP_ENABLE="true"
OC_OTP_SEND_BY_EMAIL="false"
OC_OTP_SEND_BY_TELEGRAM="false"
```

OTP uses native ocserv authentication through `ocpasswd`:

```conf
auth = "plain[passwd=/etc/ocserv/ocpasswd,otp=/etc/ocserv/secrets/users.oath]"
```

Create a user with password an OTP secret:

```bash
docker exec -it openconnect ocpasswd username

docker exec -it openconnect ocuser2fa username
```

## Revoke

```bash
docker exec -it openconnect ocrevoke username
docker exec -it openconnect ocrevoke RELOAD
docker exec -it openconnect ocrevoke RESET
```

## Split tunneling

Split tunneling requires the upstream OpenConnect client to be enabled:

```bash
OC_CLIENT_ENABLE="true"
OC_SPLIT_ENABLE="true"
```

Routes and domains can be set in `.env` or edited after startup:

```bash
./data/routes.txt
./data/domains.txt
```

Changes to these files are picked up automatically.
