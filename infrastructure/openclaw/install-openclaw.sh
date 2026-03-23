#!/usr/bin/env bash
set -Eeuo pipefail

#######################################
# OpenClaw Installer (Nginx + SSL + Basic Auth)
#######################################
#
# Author: Fernando Covecino
#
# Designed for a fresh Ubuntu 24.04 server.
# Installs and configures:
#   - Nginx (reverse proxy with WebSocket support)
#   - Let's Encrypt SSL via certbot (webroot method)
#   - Basic Auth (htpasswd)
#   - Node.js 22.x + OpenClaw
#
# USAGE:
#   sudo ./install-openclaw.sh
#
#   Must be run with sudo from a normal user (not root directly).
#   Example:
#     chmod +x install-openclaw.sh
#     sudo ./install-openclaw.sh
#
# OPTIONAL ENVIRONMENT VARIABLES:
#   DOMAIN               — If set, used without prompting.
#   CERTBOT_EMAIL        — If set, used without prompting.
#   BASIC_AUTH_USER      — If set, used without prompting.
#   BASIC_AUTH_PASSWORD   — If set, used without prompting.
#   OPENCLAW_API_KEY     — Required only if OPENCLAW_RUN_ONBOARD=true.
#
#######################################

#######################################
# Configuration variables
#######################################

# 👤 System user who will own OpenClaw
TARGET_USER="${SUDO_USER:-}"

# 🌐 Public domain and local upstream
DOMAIN="${DOMAIN:-}"                               # empty = prompt
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"                 # empty = prompt
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT="18789"

# 🔐 Basic Auth
BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"              # empty = prompt
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"      # empty = prompt

# 🦀 OpenClaw
INSTALL_OPENCLAW="true"
OPENCLAW_RUN_ONBOARD="false"

# Options for non-interactive onboarding (only if OPENCLAW_RUN_ONBOARD=true)
OPENCLAW_AUTH_CHOICE="openai-api-key"   # openai-api-key | anthropic-api-key
OPENCLAW_API_KEY="${OPENCLAW_API_KEY:-}"
OPENCLAW_GATEWAY_BIND="loopback"
OPENCLAW_GATEWAY_PORT="18789"
OPENCLAW_INSTALL_DAEMON="true"
OPENCLAW_SKIP_SKILLS="true"

# 🧪 Set to "true" to use Let's Encrypt staging (no rate limits, untrusted certs)
USE_STAGING_CERTS="false"

#######################################
# Colors and utilities
#######################################

GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

step() {
  echo
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BLUE}🚀 $*${RESET}"
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

info() {
  echo -e "   ${CYAN}→ $*${RESET}"
}

ok() {
  echo -e "   ${GREEN}✅ $*${RESET}"
}

warn() {
  echo -e "   ${YELLOW}⚠️  $*${RESET}"
}

fail() {
  echo -e "\n   ${RED}💀 ERROR: $*${RESET}\n" >&2
  exit 1
}

run_cmd() {
  info "Running: $*"
  "$@"
}

# Runs a command as TARGET_USER, passing environment variables securely.
# Usage: run_as_target_user "command" [ENV_VAR=value ...]
run_as_target_user() {
  local cmd="$1"
  shift
  local env_args=()
  for e in "$@"; do
    env_args+=(env "$e")
  done

  info "Running as ${TARGET_USER}: ${cmd}"
  if [[ ${#env_args[@]} -gt 0 ]]; then
    sudo -H -u "${TARGET_USER}" "${env_args[@]}" bash -lc "$cmd"
  else
    sudo -H -u "${TARGET_USER}" bash -lc "$cmd"
  fi
}

trap 'fail "Script stopped at line ${LINENO}. Check the message above."' ERR

#######################################
# Banner
#######################################

clear || true
echo
echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${MAGENTA}║${RESET}  ${CYAN}🦀 OpenClaw Installer${RESET}                                   ${MAGENTA}║${RESET}"
echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "   ${GREEN}1${RESET}. Install Nginx 🌐"
echo -e "   ${GREEN}2${RESET}. Install Node.js + OpenClaw 🦀"
echo -e "   ${GREEN}3${RESET}. Configure reverse proxy + WebSocket 🔁"
echo -e "   ${GREEN}4${RESET}. Enable SSL via Let's Encrypt 🔒"
echo -e "   ${GREEN}5${RESET}. Configure Basic Auth 🔐"
echo

#######################################
# Prerequisites
#######################################

step "Checking prerequisites"

[[ $EUID -eq 0 ]] || fail "This script must be run as root or with sudo."
ok "Root privileges detected"

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  fail "Could not detect a normal user in SUDO_USER. Run: sudo ./$(basename "$0") from your regular user."
fi

id "${TARGET_USER}" >/dev/null 2>&1 || fail "User '${TARGET_USER}' does not exist."
ok "System user '${TARGET_USER}' ready"

#######################################
# Interactive prompts for missing values
#######################################

step "Gathering configuration details"

# --- Domain ---
if [[ -z "${DOMAIN}" ]]; then
  echo -e "   ${CYAN}🌐 Where shall the claw reside on the internet?${RESET}"
  echo -e "   ${CYAN}   (e.g. oc.example.com — no https://, just the hostname)${RESET}"
  echo -e "   ${CYAN}   Make sure the DNS A record already points here — SSL won't${RESET}"
  echo -e "   ${CYAN}   negotiate with a domain that ghosts this server. 👻${RESET}"
  read -rp "   🌐 Domain: " DOMAIN
  [[ -n "${DOMAIN}" ]] || fail "A domain is required — the crab needs a home!"
  ok "Domain set: ${DOMAIN}"
else
  ok "Using domain from environment variable: ${DOMAIN}"
fi

# --- Certbot email ---
if [[ -z "${CERTBOT_EMAIL}" ]]; then
  echo -e "   ${CYAN}📧 Email for Let's Encrypt (certificate expiry warnings).${RESET}"
  read -rp "   📧 Email: " CERTBOT_EMAIL
  [[ -n "${CERTBOT_EMAIL}" ]] || fail "An email is required for Let's Encrypt."
  ok "Email set: ${CERTBOT_EMAIL}"
else
  ok "Using certbot email from environment variable: ${CERTBOT_EMAIL}"
fi

# --- Basic Auth user ---
if [[ -z "${BASIC_AUTH_USER}" ]]; then
  echo -e "   ${CYAN}👤 Pick a username for the bouncer at the door (Basic Auth).${RESET}"
  echo -e "   ${CYAN}   Pro tip: 'admin' works, but something memorable is even better.${RESET}"
  read -rp "   👤 Username: " BASIC_AUTH_USER
  [[ -n "${BASIC_AUTH_USER}" ]] || fail "Username cannot be empty — even crabs have names!"
  ok "Username set: ${BASIC_AUTH_USER}"
else
  ok "Using Basic Auth user from environment variable: ${BASIC_AUTH_USER}"
fi

if [[ "${BASIC_AUTH_USER}" == *:* ]]; then
  fail "Username cannot contain ':' — htpasswd format restriction."
fi

# --- Basic Auth password ---
if [[ -z "${BASIC_AUTH_PASSWORD}" ]]; then
  echo -e "   ${CYAN}🔑 Now give that bouncer a secret passphrase.${RESET}"
  echo -e "   ${CYAN}   Make it strong — crabs are tough, your password should be too.${RESET}"
  read -rsp "   🔑 Password for '${BASIC_AUTH_USER}': " BASIC_AUTH_PASSWORD
  echo
  read -rsp "   🔁 Type it again (trust issues, sorry): " pw_confirm
  echo
  [[ "${BASIC_AUTH_PASSWORD}" == "${pw_confirm}" ]] || fail "Passwords do not match — the crab is confused."
  unset pw_confirm
  ok "Password captured"
else
  ok "Using password from environment variable"
fi

[[ -n "${BASIC_AUTH_PASSWORD}" ]] || fail "The Basic Auth password cannot be empty."

#######################################
# Derived paths
#######################################

WEBROOT="/var/www/${DOMAIN}"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}"
HTPASSWD_DIR="/etc/nginx/auth"
HTPASSWD_FILE="${HTPASSWD_DIR}/${DOMAIN}.htpasswd"

#######################################
# Base dependencies
#######################################

step "Installing base dependencies"

export DEBIAN_FRONTEND=noninteractive
run_cmd apt-get update -y
run_cmd apt-get install -y curl ca-certificates gnupg lsb-release sudo dnsutils apache2-utils

ok "Base dependencies ready 📦"

#######################################
# Install Nginx
#######################################

step "Installing Nginx"

if command -v nginx >/dev/null 2>&1; then
  ok "Nginx already installed: $(nginx -v 2>&1 || true)"
else
  run_cmd apt-get install -y nginx
  ok "Nginx installed: $(nginx -v 2>&1 || true)"
fi

run_cmd systemctl enable nginx
run_cmd systemctl start nginx
ok "Nginx running"

# Remove default site if it exists
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
  info "Removed default site"
fi

# WebSocket upgrade map — placed in conf.d/ (included in http {} by default)
WS_MAP="/etc/nginx/conf.d/websocket-upgrade-map.conf"
if [[ ! -f "${WS_MAP}" ]]; then
  cat > "${WS_MAP}" <<'WSEOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
WSEOF
  ok "WebSocket upgrade map created"
else
  ok "WebSocket upgrade map already exists"
fi

#######################################
# Install Certbot
#######################################

step "Installing Certbot"

if command -v certbot >/dev/null 2>&1; then
  ok "Certbot already installed"
else
  run_cmd apt-get install -y certbot
  ok "Certbot installed"
fi

#######################################
# Install OpenClaw
#######################################

if [[ "${INSTALL_OPENCLAW}" == "true" ]]; then
  step "Installing Node.js (OpenClaw requirement)"

  if command -v node >/dev/null 2>&1; then
    node_ver=$(node -v 2>/dev/null || echo "unknown")
    ok "Node.js already installed: ${node_ver}"
  else
    info "Installing Node.js 22.x via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    run_cmd apt-get install -y nodejs
    ok "Node.js installed: $(node -v)"
  fi

  step "Installing OpenClaw 🦀"

  if sudo -H -u "${TARGET_USER}" bash -lc 'command -v openclaw' >/dev/null 2>&1; then
    ok "OpenClaw is already installed — skipping"
  else
    info "Installing OpenClaw via npm..."
    run_cmd npm install -g openclaw
    # npm installs global packages with 750 (drwxr-x---) which blocks
    # non-root users from resolving the /usr/bin/openclaw symlink target.
    chmod -R o+rX "$(npm root -g)/openclaw"
    sudo -H -u "${TARGET_USER}" bash -lc 'command -v openclaw' >/dev/null 2>&1 || \
      fail "OpenClaw installed but 'openclaw' not found in PATH."
    ok "OpenClaw installed"
  fi

  # Linger so the daemon survives logout
  if [[ "${OPENCLAW_INSTALL_DAEMON}" == "true" ]]; then
    step "Enabling linger for ${TARGET_USER}"
    run_cmd loginctl enable-linger "${TARGET_USER}" || fail "Could not enable linger."
    ok "Linger enabled — daemon will persist"
  fi

  # Non-interactive onboarding
  if [[ "${OPENCLAW_RUN_ONBOARD}" == "true" ]]; then
    step "Running OpenClaw onboarding"

    [[ -n "${OPENCLAW_API_KEY}" ]] || fail "OPENCLAW_RUN_ONBOARD=true but OPENCLAW_API_KEY is empty."

    api_env_var=""
    case "${OPENCLAW_AUTH_CHOICE}" in
      "anthropic-api-key") api_env_var="ANTHROPIC_API_KEY" ;;
      "openai-api-key")    api_env_var="OPENAI_API_KEY" ;;
      *)                   fail "Unsupported OPENCLAW_AUTH_CHOICE: ${OPENCLAW_AUTH_CHOICE}" ;;
    esac

    onboard_flags="--non-interactive --mode local --auth-choice ${OPENCLAW_AUTH_CHOICE} --gateway-port ${OPENCLAW_GATEWAY_PORT} --gateway-bind ${OPENCLAW_GATEWAY_BIND}"
    [[ "${OPENCLAW_INSTALL_DAEMON}" == "true" ]] && onboard_flags+=" --install-daemon"
    [[ "${OPENCLAW_SKIP_SKILLS}" == "true" ]] && onboard_flags+=" --skip-skills"

    run_as_target_user \
      "openclaw onboard ${onboard_flags}" \
      "${api_env_var}=${OPENCLAW_API_KEY}"

    ok "Onboarding completed 🎉"
  else
    warn "Onboarding skipped (OPENCLAW_RUN_ONBOARD=false)"
    info "To configure manually later (as ${TARGET_USER}):"
    echo -e "      ${CYAN}openclaw onboard --install-daemon${RESET}"
  fi
else
  warn "OpenClaw installation skipped (INSTALL_OPENCLAW=false)"
fi

#######################################
# Nginx + SSL + Reverse Proxy + Basic Auth
#######################################
#
# Flow:
#   1. Check if site already fully configured → skip if so
#   2. Verify DNS resolves to this server
#   3. Write temporary HTTP-only config (for ACME challenge)
#   4. Obtain SSL certificate via certbot --webroot
#   5. Write final config (HTTPS reverse proxy + WebSocket + Basic Auth)
#   6. Create htpasswd credentials
#   7. Validate and reload nginx
#
#######################################

# Check if already fully configured
if [[ -f "${NGINX_SITE}" ]] && \
   grep -q "ssl_certificate" "${NGINX_SITE}" 2>/dev/null && \
   grep -q "proxy_pass" "${NGINX_SITE}" 2>/dev/null && \
   grep -q "auth_basic" "${NGINX_SITE}" 2>/dev/null; then
  ok "Site ${DOMAIN} already configured with SSL, proxy, and Basic Auth — skipping"
  SKIP_SITE_SETUP="true"
else
  SKIP_SITE_SETUP="false"
fi

if [[ "${SKIP_SITE_SETUP}" == "false" ]]; then

  #######################################
  # DNS verification
  #######################################

  step "DNS verification"

  SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "<your-ip>")

  echo
  echo -e "   ${YELLOW}┌──────────────────────────────────────────────────────┐${RESET}"
  echo -e "   ${YELLOW}│${RESET}  ${CYAN}📋 ACTION REQUIRED: Create DNS record${RESET}               ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}├──────────────────────────────────────────────────────┤${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  Let's Encrypt requires the domain to resolve        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  to this server to issue the SSL certificate.        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  Create this record in your DNS panel:               ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Type:${RESET}   A                                        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Name:${RESET}   ${DOMAIN}$(printf '%*s' $((39 - ${#DOMAIN})) '')${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Value:${RESET}  ${SERVER_IP}$(printf '%*s' $((23 - ${#SERVER_IP})) '')${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}TTL:${RESET}    300 (or the minimum available)            ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}└──────────────────────────────────────────────────────┘${RESET}"
  echo

  info "Checking if ${DOMAIN} already resolves to ${SERVER_IP}..."
  resolved_ip=$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)

  if [[ "${resolved_ip}" == "${SERVER_IP}" ]]; then
    ok "DNS already resolves correctly: ${DOMAIN} → ${SERVER_IP}"
  else
    if [[ -n "${resolved_ip}" ]]; then
      warn "DNS resolves to ${resolved_ip} instead of ${SERVER_IP}"
    else
      warn "DNS does not resolve yet for ${DOMAIN}"
    fi
    echo
    read -rp "   ⏸️  Press ENTER once you have created the DNS record and it has propagated... " _
    echo

    resolved_ip=$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)
    if [[ "${resolved_ip}" == "${SERVER_IP}" ]]; then
      ok "DNS confirmed: ${DOMAIN} → ${SERVER_IP}"
    else
      warn "DNS still does not resolve correctly (${resolved_ip:-no response}). SSL may fail."
      read -rp "   Continue anyway? (y/N): " dns_continue
      [[ "${dns_continue}" =~ ^[yY]$ ]] || fail "Aborted. Configure DNS and re-run the script."
    fi
  fi

  #######################################
  # Obtain SSL certificate
  #######################################

  step "Obtaining SSL certificate for ${DOMAIN}"

  CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"

  if [[ -f "${CERT_PATH}" ]]; then
    ok "Certificate already exists — skipping certbot"
  else
    # Create webroot for ACME challenges
    mkdir -p "${WEBROOT}/.well-known/acme-challenge"
    chown -R www-data:www-data "${WEBROOT}"

    # Write a minimal HTTP-only config so nginx can serve the ACME challenge
    cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 503;
    }
}
EOF

    ln -sf "${NGINX_SITE}" "${NGINX_LINK}"
    nginx -t || fail "Nginx config test failed (HTTP-only config)"
    systemctl reload nginx
    ok "Temporary HTTP config active — ready for ACME challenge"

    # Build certbot command
    certbot_args=(
      certonly --webroot
      -w "${WEBROOT}"
      -d "${DOMAIN}"
      --non-interactive
      --agree-tos
      -m "${CERTBOT_EMAIL}"
      --deploy-hook "systemctl reload nginx"
    )
    if [[ "${USE_STAGING_CERTS}" == "true" ]]; then
      certbot_args+=(--test-cert)
      warn "Using Let's Encrypt STAGING — certificate will NOT be trusted by browsers"
    fi

    run_cmd certbot "${certbot_args[@]}"
    ok "SSL certificate obtained 🔒"
  fi

  #######################################
  # Write final Nginx configuration
  #######################################

  step "Writing Nginx configuration: reverse proxy + SSL + WebSocket + Basic Auth"

  mkdir -p "${HTPASSWD_DIR}"

  cat > "${NGINX_SITE}" <<EOF
# ──────────────────────────────────────────────────────
# ${DOMAIN} — OpenClaw reverse proxy
# Managed by install-openclaw.sh — edit with care
# ──────────────────────────────────────────────────────

# HTTP → HTTPS redirect (keeps /.well-known for cert renewal)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEBROOT};
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS reverse proxy
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL certificates (managed by certbot)
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # SSL settings (Mozilla Intermediate — https://ssl-config.mozilla.org)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # HSTS (2 years)
    add_header Strict-Transport-Security "max-age=63072000" always;

    # Basic Auth
    auth_basic "Restricted";
    auth_basic_user_file ${HTPASSWD_FILE};

    location / {
        proxy_pass http://${UPSTREAM_HOST}:${UPSTREAM_PORT};
        proxy_http_version 1.1;

        # Standard proxy headers
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Long-lived connections for WebSocket
        proxy_read_timeout 86400;
    }
}
EOF

  ln -sf "${NGINX_SITE}" "${NGINX_LINK}"
  ok "Nginx config written"

  #######################################
  # Basic Auth credentials
  #######################################

  step "Configuring Basic Auth"

  # -B = bcrypt, -c = create file (overwrites if exists)
  htpasswd -Bbc "${HTPASSWD_FILE}" "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASSWORD}"
  chmod 640 "${HTPASSWD_FILE}"
  chown root:www-data "${HTPASSWD_FILE}"
  ok "Basic Auth user '${BASIC_AUTH_USER}' created"

  #######################################
  # Validate and reload
  #######################################

  step "Validating and reloading Nginx"

  run_cmd nginx -t
  ok "Nginx configuration valid"

  run_cmd systemctl reload nginx
  ok "Nginx reloaded"

fi

#######################################
# Final summary
#######################################

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}  ${CYAN}🎉 Configuration completed successfully!${RESET}                  ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "   ${BLUE}🌐 Domain:${RESET}        https://${DOMAIN}"
echo -e "   ${BLUE}🔁 Proxy:${RESET}         https://${DOMAIN} → http://${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo -e "   ${BLUE}🔒 SSL:${RESET}           Let's Encrypt (auto-renews via certbot timer)"
echo -e "   ${BLUE}🔐 Basic Auth:${RESET}    ${BASIC_AUTH_USER}"
echo -e "   ${BLUE}🦀 OpenClaw:${RESET}      user=${TARGET_USER}  port=${OPENCLAW_GATEWAY_PORT}  bind=${OPENCLAW_GATEWAY_BIND}"
echo
echo -e "   ${YELLOW}📝 Next steps (as ${TARGET_USER}):${RESET}"
echo
echo -e "   ${GREEN}1.${RESET} Run OpenClaw onboarding:"
echo -e "      ${CYAN}openclaw onboard --install-daemon${RESET}"
echo
echo -e "   ${GREEN}2.${RESET} Configure allowed origins for the dashboard:"
echo -e "      ${CYAN}openclaw config set gateway.controlUi.allowedOrigins '[\"https://${DOMAIN}\"]'${RESET}"
echo -e "      ${CYAN}openclaw gateway restart${RESET}"
echo
echo -e "   ${GREEN}3.${RESET} Get the dashboard token:"
echo -e "      ${CYAN}openclaw dashboard --no-open${RESET}"
echo
echo -e "   ${GREEN}4.${RESET} Open ${CYAN}https://${DOMAIN}${RESET} in the browser."
echo -e "      Paste the token and click Connect."
echo
echo -e "   ${GREEN}5.${RESET} Approve the device from the terminal:"
echo -e "      ${CYAN}openclaw devices list${RESET}"
echo -e "      ${CYAN}openclaw devices approve <request-id>${RESET}"
echo
echo -e "   ${YELLOW}⚠️  Notes:${RESET}"
echo -e "      • SSL renews automatically (certbot systemd timer)."
echo -e "      • OpenClaw listens only on ${UPSTREAM_HOST} — do not expose port ${UPSTREAM_PORT}."
echo -e "      • Ensure ports 80 and 443 are open in your firewall (ufw, cloud security group, etc)."
echo -e "      • To add more Basic Auth users:  ${CYAN}htpasswd -B ${HTPASSWD_FILE} <username>${RESET}"
echo
echo -e "   ${GREEN}🚀 All set. Let's go! 🦞${RESET}"
echo
