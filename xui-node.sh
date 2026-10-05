#!/usr/bin/env bash
set -Eeuo pipefail

# Public bootstrap for a BOTICS-managed 3x-ui node.
# Source of truth: BOTICS_FRIENDS/deploy/xui-node/bootstrap.sh
XUI_VERSION="${BOTICS_XUI_VERSION:-v3.8.5}"
XRAY_VERSION="${BOTICS_XRAY_VERSION:-v26.7.28}"
PANEL_PORT="${BOTICS_PANEL_PORT:-2053}"
SSH_PORT="${BOTICS_SSH_PORT:-22}"
MASTER_IP="${BOTICS_MASTER_IP:-}"
INBOUND_PORTS="${BOTICS_INBOUND_PORTS:-}"
ENABLE_UFW="${BOTICS_ENABLE_UFW:-1}"
SSL_MODE="${BOTICS_XUI_SSL_MODE:-domain}"
XUI_DOMAIN="${BOTICS_XUI_DOMAIN:-}"
INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }

[[ "${EUID}" -eq 0 ]] || die "run this script as root (sudo bash ...)"
[[ -r /etc/os-release ]] || die "cannot identify the operating system"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]] || die "only Ubuntu and Debian are supported"
valid_port "$PANEL_PORT" || die "BOTICS_PANEL_PORT must be between 1 and 65535"
valid_port "$SSH_PORT" || die "BOTICS_SSH_PORT must be between 1 and 65535"
[[ "$SSL_MODE" == "ip" || "$SSL_MODE" == "domain" || "$SSL_MODE" == "none" ]] || die "BOTICS_XUI_SSL_MODE must be ip, domain, or none"
[[ "$SSL_MODE" != "domain" || -n "$XUI_DOMAIN" ]] || die "BOTICS_XUI_DOMAIN is required (for example: node1.example.com)"
[[ -z "$XUI_DOMAIN" || "$XUI_DOMAIN" != *"://"* ]] || die "BOTICS_XUI_DOMAIN must not contain http:// or https://"
[[ -z "$XUI_DOMAIN" || "$XUI_DOMAIN" != */* ]] || die "BOTICS_XUI_DOMAIN must contain only a hostname, without a path"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl ufw

if [[ "$SSL_MODE" == "domain" ]]; then
    public_ip="$(curl --fail --silent --show-error --ipv4 --max-time 15 https://api.ipify.org)" || die "cannot determine this server's public IPv4 address"
    mapfile -t domain_ips < <(getent ahostsv4 "$XUI_DOMAIN" | awk '{print $1}' | sort -u)
    (( ${#domain_ips[@]} > 0 )) || die "$XUI_DOMAIN has no public A record yet"
    printf 'Server public IPv4: %s\n' "$public_ip"
    printf '%s A record(s): %s\n' "$XUI_DOMAIN" "${domain_ips[*]}"
    [[ " ${domain_ips[*]} " == *" $public_ip "* ]] || die "$XUI_DOMAIN does not point to this server ($public_ip)"
fi

if ! command -v x-ui >/dev/null 2>&1 && [[ ! -x /usr/local/x-ui/x-ui ]]; then
    installer="$(mktemp /tmp/botics-xui-install.XXXXXX)"
    trap 'rm -f "${installer:-}"' EXIT
    curl --fail --silent --show-error --location "$INSTALL_URL" --output "$installer"
    chmod 0700 "$installer"
    export XUI_NONINTERACTIVE=1
    export XUI_PANEL_PORT="$PANEL_PORT"
    export XUI_SSL_MODE="$SSL_MODE"
    if [[ -n "$XUI_DOMAIN" ]]; then
        export XUI_DOMAIN
    fi
    bash "$installer" "$XUI_VERSION"
else
    printf '3x-ui is already installed; skipping installation.\n'
fi

systemctl enable --now x-ui

RESULT_FILE="/etc/x-ui/install-result.env"
[[ -r "$RESULT_FILE" ]] || die "3x-ui did not create $RESULT_FILE"
# shellcheck disable=SC1090
. "$RESULT_FILE"
[[ -n "${XUI_ACCESS_URL:-}" && -n "${XUI_API_TOKEN:-}" ]] || die "panel URL or API token is missing from $RESULT_FILE"

xray_response="$(mktemp /tmp/botics-xray-response.XXXXXX)"
trap 'rm -f "${installer:-}" "${xray_response:-}"' EXIT
curl --fail --silent --show-error --location \
    --connect-timeout 15 --max-time 600 \
    --retry 10 --retry-connrefused --retry-delay 2 \
    --request POST \
    --header "Authorization: Bearer ${XUI_API_TOKEN}" \
    --header "Accept: application/json" \
    "${XUI_ACCESS_URL%/}/panel/api/server/installXray/${XRAY_VERSION}" \
    --output "$xray_response"
grep -Eq '"success"[[:space:]]*:[[:space:]]*true' "$xray_response" || {
    printf '3x-ui could not install Xray-core %s. API response:\n' "$XRAY_VERSION" >&2
    sed -E 's/(token|apiToken)"?[[:space:]]*:[[:space:]]*"[^"]+"/\1":"[redacted]"/g' "$xray_response" >&2
    exit 1
}
printf 'Xray-core %s installed successfully.\n' "$XRAY_VERSION"

if [[ "$ENABLE_UFW" == "1" ]]; then
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    if [[ "$SSL_MODE" != "none" ]]; then
        ufw allow "80/tcp" comment 'ACME certificate renewal'
    fi
    if [[ -n "$MASTER_IP" ]]; then
        ufw allow from "$MASTER_IP" to any port "$PANEL_PORT" proto tcp comment '3x-ui master API'
    else
        printf 'WARNING: BOTICS_MASTER_IP is empty; panel port will be reachable from anywhere.\n' >&2
        ufw allow "${PANEL_PORT}/tcp" comment '3x-ui panel API'
    fi
    IFS=',' read -r -a ports <<< "$INBOUND_PORTS"
    for port in "${ports[@]}"; do
        port="${port//[[:space:]]/}"
        [[ -z "$port" ]] && continue
        valid_port "$port" || die "invalid port in BOTICS_INBOUND_PORTS: $port"
        ufw allow "${port}/tcp" comment '3x-ui inbound'
        ufw allow "${port}/udp" comment '3x-ui inbound'
    done
    ufw --force enable
fi

printf '\n3x-ui node is ready.\n'
printf 'Pinned versions: panel %s, Xray-core %s.\n' "$XUI_VERSION" "$XRAY_VERSION"
printf 'Credentials and one-time API token (root only):\n'
printf '  sudo cat /etc/x-ui/install-result.env\n'
printf 'Service check:\n'
printf '  sudo systemctl status x-ui --no-pager\n'
printf '\nCopy only panel URL/port/base path/API token into BOTICS admin. Never publish the credentials file.\n'
