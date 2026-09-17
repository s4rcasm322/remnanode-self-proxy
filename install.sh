#!/usr/bin/env bash

# If somebody runs "sh install.sh", re-exec with Bash before any Bash-only syntax.
if [ -z "${BASH_VERSION:-}" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi

set -Eeuo pipefail
umask 022

readonly WEB_ROOT="/var/www/liquidvpn"
readonly NGINX_SITE="/etc/nginx/sites-available/liquidvpn"
readonly NGINX_LINK="/etc/nginx/sites-enabled/liquidvpn"
readonly SYSCTL_FILE="/etc/sysctl.d/99-remnawave-xhttp.conf"
readonly SWAP_FILE="/swapfile"
readonly REMNA_URL="https://github.com/DigneZzZ/remnawave-scripts/raw/main/remnanode.sh"
readonly REMNA_NODE_PORT="2222"
readonly REMNA_COMPOSE="/opt/remnanode/docker-compose.yml"
readonly INSTALLER_VERSION="6.1"

DOMAIN=""
CERT_DIR=""
PUBLIC_IPV4=""
DOMAIN_A=""
DOMAIN_AAAA=""
NGINX_MAIN_BACKUP=""
NGINX_SITE_BACKUP=""
REMNA_TMP=""
UFW_WAS_ACTIVE=0

log() {
    printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

prompt() {
    local __var="$1"
    local __text="$2"
    local __value=""

    [[ -r /dev/tty && -w /dev/tty ]] || die "Interactive terminal /dev/tty is required."

    printf '%s' "$__text" >/dev/tty
    IFS= read -r __value </dev/tty || die "Unable to read from terminal."
    printf -v "$__var" '%s' "$__value"
}

run_pkg_command() {
    local tmp
    local rc
    local started
    local elapsed
    local owner
    local max_wait=1200
    local retry_delay=5
    local attempt=1

    started="${SECONDS}"

    while true; do
        tmp="$(mktemp /tmp/liquidvpn-pkg.XXXXXX.log)"

        # Run the REAL package-manager command. Do not try to infer whether APT
        # is busy from process names or lock files beforehand.
        set +e
        "$@" 2>&1 | tee "${tmp}"
        rc=${PIPESTATUS[0]}
        set -e

        if (( rc == 0 )); then
            rm -f "${tmp}"
            return 0
        fi

        if grep -Eqi \
            'Could not get lock|Unable to acquire.*lock|is held by process|is another process using it|Could not open lock file|Resource temporarily unavailable' \
            "${tmp}"
        then
            elapsed=$((SECONDS - started))

            if (( elapsed >= max_wait )); then
                warn "Package manager remained locked for ${max_wait}s."
                cat "${tmp}" >&2 || true
                rm -f "${tmp}"
                return "${rc}"
            fi

            owner="$(
                grep -Eio \
                    'held by process[[:space:]]+[0-9]+([[:space:]]+\([^)]*\))?' \
                    "${tmp}" \
                    | head -n 1 \
                    || true
            )"

            if [[ -n "${owner}" ]]; then
                warn "Package manager is locked (${owner})."
            else
                warn "Package manager is temporarily locked."
            fi

            echo "Retrying in ${retry_delay}s... (${elapsed}s / ${max_wait}s)"
            rm -f "${tmp}"
            sleep "${retry_delay}"
            attempt=$((attempt + 1))
            continue
        fi

        # Not a lock error: preserve the real error code and stop immediately.
        rm -f "${tmp}"
        return "${rc}"
    done
}

configure_remnanode_hysteria() {
    local compose="${REMNA_COMPOSE}"
    local backup
    local mount_state

    [[ -f "${compose}" ]] || die "RemnaNode compose file was not found: ${compose}"
    command -v docker >/dev/null 2>&1 || die "Docker is not available after RemnaNode installation."

    log "Configuring RemnaNode Docker for Hysteria2..."

    # RemnaNode should use host networking. This is required for inbound
    # protocols such as Hysteria2 to bind directly to the host UDP ports.
    if ! grep -Eq '^[[:space:]]*network_mode:[[:space:]]*host[[:space:]]*$' "${compose}"; then
        die "RemnaNode compose does not use network_mode: host; refusing to patch unexpected layout."
    fi

    backup="${compose}.pre-hysteria.$(date +%Y%m%d-%H%M%S)"
    cp -a "${compose}" "${backup}"

    # Hysteria2 TLS configuration inside Xray needs access to the real
    # Let's Encrypt files. Mount the WHOLE /etc/letsencrypt tree because
    # files in /live are symlinks to /archive.
    if grep -Fq '/etc/letsencrypt:/etc/letsencrypt:ro' "${compose}"; then
        ok "Let's Encrypt certificates are already mounted into RemnaNode."
    else
        if grep -Eq '^    volumes:[[:space:]]*$' "${compose}"; then
            # Existing active volumes section.
            sed -i \
                '/^    volumes:[[:space:]]*$/a\      - /etc/letsencrypt:/etc/letsencrypt:ro' \
                "${compose}"

        elif grep -Eq '^    #[[:space:]]*volumes:[[:space:]]*$' "${compose}"; then
            # Official RemnaNode installer normally creates a commented
            # volumes section for optional features. Reuse it instead of
            # creating a second YAML "volumes" key.
            sed -i \
                's/^    #[[:space:]]*volumes:[[:space:]]*$/    volumes:/' \
                "${compose}"

            sed -i \
                '/^    volumes:[[:space:]]*$/a\      - /etc/letsencrypt:/etc/letsencrypt:ro' \
                "${compose}"

        else
            # Fallback for future compose layouts.
            sed -i \
                '/^[[:space:]]*network_mode:[[:space:]]*host[[:space:]]*$/i\
    volumes:\
      - /etc/letsencrypt:/etc/letsencrypt:ro' \
                "${compose}"
        fi
    fi

    log "Validating RemnaNode Docker Compose configuration..."

    if ! (
        cd /opt/remnanode
        docker compose config >/dev/null
    ); then
        cp -a "${backup}" "${compose}"
        die "Docker Compose validation failed after Hysteria2 changes; original compose restored."
    fi

    log "Recreating RemnaNode with Hysteria2 certificate access..."

    if ! (
        cd /opt/remnanode
        docker compose up -d --force-recreate
    ); then
        cp -a "${backup}" "${compose}"

        (
            cd /opt/remnanode
            docker compose up -d --force-recreate
        ) || true

        die "Failed to recreate RemnaNode; original compose restored."
    fi

    # Verify Docker actually applied the bind mount.
    mount_state="$(
        docker inspect remnanode \
            --format '{{range .Mounts}}{{if eq .Destination "/etc/letsencrypt"}}{{.Source}}|{{.Destination}}|{{.RW}}{{end}}{{end}}' \
            2>/dev/null \
            || true
    )"

    if [[ "${mount_state}" == "/etc/letsencrypt|/etc/letsencrypt|false" ]]; then
        ok "Let's Encrypt is mounted read-only inside RemnaNode."
    else
        warn "Expected Let's Encrypt bind mount was not found after container recreation."

        cp -a "${backup}" "${compose}"

        (
            cd /opt/remnanode
            docker compose up -d --force-recreate
        ) || true

        die "Hysteria2 Docker configuration verification failed; original compose restored."
    fi

    ok "RemnaNode Docker is ready for Hysteria2 on UDP/443."
}

cleanup() {
    if [[ -n "${REMNA_TMP:-}" && -f "${REMNA_TMP}" ]]; then
        rm -f "${REMNA_TMP}"
    fi
}
trap cleanup EXIT

trap '
    rc=$?
    printf "\n\033[1;31m[ERROR]\033[0m Command failed at line %s: %s (exit %s)\n" \
        "$LINENO" "$BASH_COMMAND" "$rc" >&2
    exit "$rc"
' ERR

[[ "${EUID}" -eq 0 ]] || die "Run this script as root."

[[ -f /etc/os-release ]] || die "Unable to detect operating system."
# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        die "Supported operating systems: Ubuntu and Debian. Detected: ${ID:-unknown}"
        ;;
esac

log "LiquidVPN / RemnaNode installer v${INSTALLER_VERSION}"

while true; do
    prompt DOMAIN "Enter node domain (example: pl-node1.liquidvpn.org): "
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"

    if [[ "${DOMAIN}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
        break
    fi

    warn "Invalid domain: ${DOMAIN}"
done

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

declare -A SSH_PORT_SET=()

add_port() {
    local p="${1:-}"
    if [[ "${p}" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
        SSH_PORT_SET["${p}"]=1
    fi
}

# Always preserve the standard SSH port requested by the original setup.
add_port 22

# Most reliable source when the installer itself is started over SSH.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    current_ssh_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}" 2>/dev/null || true)"
    add_port "${current_ssh_port}"
fi

# Also inspect sshd configuration.
if command -v sshd >/dev/null 2>&1; then
    while IFS= read -r p; do
        add_port "${p}"
    done < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' || true)
fi

# And currently listening sshd sockets.
if command -v ss >/dev/null 2>&1; then
    while IFS= read -r addr; do
        p="${addr##*:}"
        p="${p//]/}"
        add_port "${p}"
    done < <(ss -H -lntp 2>/dev/null | awk '/sshd/ {print $4}' || true)
fi

mapfile -t SSH_PORTS < <(printf '%s\n' "${!SSH_PORT_SET[@]}" | sort -n)

echo
echo "Domain: ${DOMAIN}"
echo "SSH port(s) that will be preserved: ${SSH_PORTS[*]}"
echo
prompt CONFIRM "Continue installation? [Y/n]: "
if [[ "${CONFIRM:-Y}" =~ ^[Nn]$ ]]; then
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating package lists..."

# Ubuntu/Debian may run apt-daily/unattended-upgrades during first boot.
# We let the actual apt-get command decide whether a lock exists and retry only
# when apt-get itself reports a real lock conflict.
run_pkg_command \
    apt-get \
    -o DPkg::Lock::Timeout=30 \
    update

# Repair an interrupted dpkg transaction if one exists.
if dpkg --audit 2>/dev/null | grep -q .; then
    warn "DPKG reports unfinished package configuration. Repairing it first..."

    run_pkg_command \
        env DEBIAN_FRONTEND=noninteractive \
        dpkg --configure -a
fi

log "Installing required packages..."

run_pkg_command \
    apt-get \
    -o DPkg::Lock::Timeout=30 \
    install -y \
    nginx \
    certbot \
    ufw \
    curl \
    ca-certificates \
    dnsutils \
    iproute2

ok "Required packages installed."

# ------------------------------------------------------------------
# Preserve remote access before touching anything firewall-related.
# If UFW is already active, these rules take effect immediately.
# If it is inactive, we only stage the rules and enable it at the end.
# ------------------------------------------------------------------

if ufw status 2>/dev/null | grep -q '^Status: active'; then
    UFW_WAS_ACTIVE=1
fi

log "Staging safe firewall rules..."

for p in "${SSH_PORTS[@]}"; do
    ufw allow "${p}/tcp"
done

ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow "${REMNA_NODE_PORT}/tcp"

ok "SSH/HTTP/HTTPS/Hysteria2 UDP/RemnaNode firewall rules staged. UFW has not been newly enabled yet."

# ------------------------------------------------------------------
# sysctl / BBR
# ------------------------------------------------------------------

log "Configuring sysctl and BBR..."
cat >"${SYSCTL_FILE}" <<'SYSCTL_EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
fs.file-max=1048576
SYSCTL_EOF

sysctl --system

BBR_CURRENT="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
if [[ "${BBR_CURRENT}" == "bbr" ]]; then
    ok "BBR is enabled."
else
    warn "BBR was requested, but current congestion control is: ${BBR_CURRENT:-unknown}"
fi

# ------------------------------------------------------------------
# nginx limits — backup first, validate after editing
# ------------------------------------------------------------------

log "Configuring nginx limits..."

NGINX_MAIN_BACKUP="/etc/nginx/nginx.conf.pre-liquidvpn.$(date +%Y%m%d-%H%M%S)"
cp -a /etc/nginx/nginx.conf "${NGINX_MAIN_BACKUP}"

sed -i '/^[[:space:]]*worker_rlimit_nofile[[:space:]]/d' /etc/nginx/nginx.conf
sed -i '/^[[:space:]]*events[[:space:]]*{/i worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf

if grep -qE '^[[:space:]]*worker_connections[[:space:]]+' /etc/nginx/nginx.conf; then
    sed -i \
        's/^[[:space:]]*worker_connections[[:space:]].*/    worker_connections 65535;/' \
        /etc/nginx/nginx.conf
else
    sed -i \
        '/^[[:space:]]*events[[:space:]]*{/a\    worker_connections 65535;' \
        /etc/nginx/nginx.conf
fi

if ! nginx -t; then
    cp -a "${NGINX_MAIN_BACKUP}" /etc/nginx/nginx.conf
    nginx -t || true
    die "nginx.conf tuning failed; original nginx.conf was restored."
fi

ok "nginx limits configured."

# ------------------------------------------------------------------
# Swap — never delete an active swapfile
# ------------------------------------------------------------------

log "Checking swap..."

if swapon --noheadings --show=NAME 2>/dev/null | awk '{$1=$1};1' | grep -Fxq "${SWAP_FILE}"; then
    ok "${SWAP_FILE} is already active; leaving it untouched."
else
    if [[ -e "${SWAP_FILE}" ]]; then
        BACKUP_SWAP="${SWAP_FILE}.pre-liquidvpn.$(date +%Y%m%d-%H%M%S)"
        mv "${SWAP_FILE}" "${BACKUP_SWAP}"
        warn "Existing inactive ${SWAP_FILE} moved to ${BACKUP_SWAP}"
    fi

    SWAP_TMP="${SWAP_FILE}.new.$$"

    if ! fallocate -l 2G "${SWAP_TMP}" 2>/dev/null; then
        dd if=/dev/zero of="${SWAP_TMP}" bs=1M count=2048 status=progress
    fi

    chmod 600 "${SWAP_TMP}"
    mkswap "${SWAP_TMP}"
    mv "${SWAP_TMP}" "${SWAP_FILE}"
    swapon "${SWAP_FILE}"

    sed -i '\|^[[:space:]]*/swapfile[[:space:]]|d' /etc/fstab
    echo '/swapfile none swap sw 0 0' >> /etc/fstab

    ok "2 GB swap configured."
fi

# ------------------------------------------------------------------
# Website
# ------------------------------------------------------------------

log "Creating fallback website..."
mkdir -p "${WEB_ROOT}/.well-known/acme-challenge"

cat >"${WEB_ROOT}/index.html" <<'HTML_INDEX_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="index, follow">
  <meta name="description" content="Download videos from the web quickly and easily.">
  <title>ClipFetch — Online Video Downloader</title>

  <style>
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    :root {
      --bg: #0b1020;
      --bg-soft: #11182c;
      --card: rgba(255, 255, 255, 0.055);
      --card-border: rgba(255, 255, 255, 0.09);
      --text: #f5f7ff;
      --muted: #9ca8c4;
      --primary: #7c5cff;
      --primary-2: #4f8cff;
      --border: rgba(255, 255, 255, 0.10);
    }

    html {
      scroll-behavior: smooth;
    }

    body {
      min-height: 100vh;
      background:
        radial-gradient(circle at 50% -20%, rgba(124,92,255,.20), transparent 35%),
        radial-gradient(circle at 85% 35%, rgba(79,140,255,.08), transparent 30%),
        var(--bg);
      color: var(--text);
      font-family: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI",
                   Roboto, Helvetica, Arial, sans-serif;
      line-height: 1.5;
    }

    .container {
      width: min(1100px, calc(100% - 40px));
      margin: 0 auto;
    }

    header {
      height: 76px;
      display: flex;
      align-items: center;
      border-bottom: 1px solid rgba(255,255,255,.06);
    }

    nav {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 11px;
      color: white;
      text-decoration: none;
      font-weight: 700;
      font-size: 20px;
      letter-spacing: -0.4px;
    }

    .logo {
      width: 34px;
      height: 34px;
      border-radius: 10px;
      background: linear-gradient(135deg, var(--primary), var(--primary-2));
      display: grid;
      place-items: center;
      box-shadow: 0 8px 30px rgba(105, 91, 255, .28);
    }

    .logo::after {
      content: "";
      width: 0;
      height: 0;
      border-top: 7px solid transparent;
      border-bottom: 7px solid transparent;
      border-left: 11px solid white;
      margin-left: 3px;
    }

    .nav-links {
      display: flex;
      gap: 28px;
    }

    .nav-links a {
      color: var(--muted);
      text-decoration: none;
      font-size: 14px;
      transition: color .2s ease;
    }

    .nav-links a:hover {
      color: white;
    }

    main {
      padding: 100px 0 90px;
    }

    .hero {
      text-align: center;
      max-width: 850px;
      margin: 0 auto;
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 7px 13px;
      border: 1px solid var(--border);
      border-radius: 999px;
      background: rgba(255,255,255,.04);
      color: #b7c1db;
      font-size: 13px;
      margin-bottom: 25px;
    }

    .badge-dot {
      width: 7px;
      height: 7px;
      border-radius: 50%;
      background: #5ee6a8;
      box-shadow: 0 0 12px rgba(94,230,168,.6);
    }

    h1 {
      font-size: clamp(42px, 7vw, 72px);
      line-height: 1.04;
      letter-spacing: -3px;
      margin-bottom: 22px;
    }

    .gradient {
      background: linear-gradient(90deg, #b765ff, #668cff);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
    }

    .subtitle {
      color: var(--muted);
      font-size: 18px;
      max-width: 620px;
      margin: 0 auto 40px;
    }

    .download-box {
      padding: 10px;
      display: flex;
      gap: 10px;
      max-width: 760px;
      margin: 0 auto;
      background: rgba(255,255,255,.07);
      border: 1px solid rgba(255,255,255,.12);
      border-radius: 18px;
      box-shadow: 0 25px 70px rgba(0,0,0,.25);
      backdrop-filter: blur(12px);
    }

    .download-box input {
      flex: 1;
      min-width: 0;
      border: 0;
      outline: 0;
      background: transparent;
      color: white;
      padding: 0 16px;
      font-size: 15px;
    }

    .download-box input::placeholder {
      color: #78839e;
    }

    button {
      border: 0;
      cursor: pointer;
      color: white;
      font-size: 14px;
      font-weight: 650;
      padding: 15px 24px;
      border-radius: 12px;
      background: linear-gradient(135deg, var(--primary), var(--primary-2));
      box-shadow: 0 8px 25px rgba(100,90,255,.25);
      transition: transform .15s ease, opacity .15s ease;
    }

    button:hover {
      transform: translateY(-1px);
    }

    .message {
      height: 24px;
      margin-top: 13px;
      color: #aab5ce;
      font-size: 13px;
    }

    .features {
      margin-top: 100px;
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 18px;
    }

    .feature {
      padding: 28px;
      border: 1px solid var(--card-border);
      border-radius: 18px;
      background: var(--card);
      text-align: left;
    }

    .feature-icon {
      width: 42px;
      height: 42px;
      border-radius: 12px;
      display: grid;
      place-items: center;
      margin-bottom: 20px;
      font-size: 19px;
      background: rgba(124,92,255,.14);
      color: #a995ff;
    }

    .feature h3 {
      font-size: 16px;
      margin-bottom: 8px;
    }

    .feature p {
      font-size: 14px;
      color: var(--muted);
    }

    footer {
      border-top: 1px solid rgba(255,255,255,.07);
      padding: 30px 0 40px;
      color: #75809a;
      font-size: 13px;
    }

    .footer-inner {
      display: flex;
      justify-content: space-between;
      gap: 20px;
    }

    .footer-links {
      display: flex;
      gap: 20px;
    }

    .footer-links a {
      color: #75809a;
      text-decoration: none;
    }

    @media (max-width: 720px) {
      .nav-links {
        display: none;
      }

      main {
        padding-top: 70px;
      }

      h1 {
        letter-spacing: -2px;
      }

      .download-box {
        flex-direction: column;
      }

      .download-box input {
        padding: 15px;
      }

      .features {
        grid-template-columns: 1fr;
        margin-top: 70px;
      }

      .footer-inner {
        flex-direction: column;
      }
    }
  </style>
</head>

<body>

<header>
  <div class="container">
    <nav>
      <a class="brand" href="/">
        <span class="logo"></span>
        ClipFetch
      </a>

      <div class="nav-links">
        <a href="/">Home</a>
        <a href="#features">Features</a>
        <a href="#about">About</a>
      </div>
    </nav>
  </div>
</header>

<main>
  <div class="container">

    <section class="hero">
      <div class="badge">
        <span class="badge-dot"></span>
        Online video downloader
      </div>

      <h1>
        Download videos<br>
        <span class="gradient">from anywhere.</span>
      </h1>

      <p class="subtitle">
        Save videos from your favorite websites in just a few clicks.
        Paste a link below to get started.
      </p>

      <form class="download-box" id="downloadForm">
        <input
          id="videoUrl"
          type="url"
          autocomplete="off"
          placeholder="Paste a video link here..."
          required
        >
        <button type="submit">Download</button>
      </form>

      <div class="message" id="message"></div>
    </section>

    <section class="features" id="features">

      <article class="feature">
        <div class="feature-icon">⚡</div>
        <h3>Fast processing</h3>
        <p>
          Paste your link and we'll prepare the video in just a few moments.
        </p>
      </article>

      <article class="feature">
        <div class="feature-icon">◇</div>
        <h3>No registration</h3>
        <p>
          No accounts or unnecessary steps. Just paste a link and continue.
        </p>
      </article>

      <article class="feature">
        <div class="feature-icon">↓</div>
        <h3>Multiple formats</h3>
        <p>
          Download content in commonly supported video and audio formats.
        </p>
      </article>

    </section>

  </div>
</main>

<footer id="about">
  <div class="container footer-inner">
    <div>© 2026 ClipFetch</div>

    <div class="footer-links">
      <a href="/">Home</a>
      <a href="/privacy">Privacy</a>
      <a href="/terms">Terms</a>
    </div>
  </div>
</footer>

<script>
  const form = document.getElementById("downloadForm");
  const input = document.getElementById("videoUrl");
  const message = document.getElementById("message");

  form.addEventListener("submit", function (event) {
    event.preventDefault();

    if (!input.value.trim()) {
      return;
    }

    message.textContent = "Unable to process this link right now. Please try again later.";
  });
</script>

</body>
</html>
HTML_INDEX_EOF

cat >"${WEB_ROOT}/404.html" <<'HTML_404_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="noindex">
  <title>Page not found — ClipFetch</title>

  <style>
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }

    :root {
      --bg: #0b1020;
      --text: #f5f7ff;
      --muted: #9ca8c4;
      --primary: #7c5cff;
      --primary-2: #4f8cff;
    }

    body {
      min-height: 100vh;
      background:
        radial-gradient(circle at 50% 20%, rgba(124,92,255,.18), transparent 35%),
        #0b1020;
      color: var(--text);
      font-family: Inter, -apple-system, BlinkMacSystemFont, "Segoe UI",
                   Roboto, Helvetica, Arial, sans-serif;
    }

    .page {
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }

    .container {
      width: min(1100px, calc(100% - 40px));
      margin: 0 auto;
    }

    header {
      height: 76px;
      display: flex;
      align-items: center;
      border-bottom: 1px solid rgba(255,255,255,.06);
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 11px;
      color: white;
      text-decoration: none;
      font-weight: 700;
      font-size: 20px;
    }

    .logo {
      width: 34px;
      height: 34px;
      border-radius: 10px;
      background: linear-gradient(135deg, var(--primary), var(--primary-2));
      display: grid;
      place-items: center;
    }

    .logo::after {
      content: "";
      width: 0;
      height: 0;
      border-top: 7px solid transparent;
      border-bottom: 7px solid transparent;
      border-left: 11px solid white;
      margin-left: 3px;
    }

    main {
      flex: 1;
      display: grid;
      place-items: center;
      padding: 60px 20px;
      text-align: center;
    }

    .error {
      max-width: 620px;
    }

    .code {
      font-size: clamp(110px, 24vw, 190px);
      line-height: .9;
      font-weight: 800;
      letter-spacing: -10px;
      background: linear-gradient(
        180deg,
        rgba(160,145,255,.9),
        rgba(79,140,255,.18)
      );
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
      user-select: none;
    }

    h1 {
      font-size: 36px;
      margin-top: 25px;
      margin-bottom: 12px;
      letter-spacing: -1px;
    }

    p {
      color: var(--muted);
      font-size: 17px;
      margin-bottom: 30px;
    }

    .button {
      display: inline-block;
      color: white;
      text-decoration: none;
      font-size: 14px;
      font-weight: 650;
      padding: 14px 23px;
      border-radius: 12px;
      background: linear-gradient(135deg, var(--primary), var(--primary-2));
      box-shadow: 0 10px 30px rgba(100,90,255,.25);
    }

    footer {
      border-top: 1px solid rgba(255,255,255,.07);
      padding: 28px 0;
      color: #75809a;
      font-size: 13px;
    }

    .footer {
      display: flex;
      justify-content: space-between;
      gap: 20px;
    }

    @media (max-width: 600px) {
      .code {
        letter-spacing: -6px;
      }

      .footer {
        flex-direction: column;
      }
    }
  </style>
</head>

<body>

<div class="page">

  <header>
    <div class="container">
      <a class="brand" href="/">
        <span class="logo"></span>
        ClipFetch
      </a>
    </div>
  </header>

  <main>
    <div class="error">
      <div class="code">404</div>

      <h1>Page not found</h1>

      <p>
        The page you're looking for doesn't exist,
        has been moved, or is temporarily unavailable.
      </p>

      <a class="button" href="/">Back to home</a>
    </div>
  </main>

  <footer>
    <div class="container footer">
      <div>© 2026 ClipFetch</div>
      <div>Fast. Simple. Free.</div>
    </div>
  </footer>

</div>

</body>
</html>
HTML_404_EOF

chown -R root:root "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 755 {} \;
find "${WEB_ROOT}" -type f -exec chmod 644 {} \;

ok "Fallback website created."

# ------------------------------------------------------------------
# Temporary HTTP nginx site for ACME
# ------------------------------------------------------------------

log "Creating temporary nginx HTTP configuration..."

if [[ -e "${NGINX_SITE}" ]]; then
    NGINX_SITE_BACKUP="${NGINX_SITE}.pre-liquidvpn.$(date +%Y%m%d-%H%M%S)"
    cp -a "${NGINX_SITE}" "${NGINX_SITE_BACKUP}"
fi

NGINX_SITE_TMP="${NGINX_SITE}.tmp.$$"

cat >"${NGINX_SITE_TMP}" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    root ${WEB_ROOT};

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

mv "${NGINX_SITE_TMP}" "${NGINX_SITE}"
ln -sfn "${NGINX_SITE}" "${NGINX_LINK}"
rm -f /etc/nginx/sites-enabled/default

if ! nginx -t; then
    if [[ -n "${NGINX_SITE_BACKUP}" && -f "${NGINX_SITE_BACKUP}" ]]; then
        cp -a "${NGINX_SITE_BACKUP}" "${NGINX_SITE}"
    else
        rm -f "${NGINX_SITE}" "${NGINX_LINK}"
    fi
    nginx -t || true
    die "Temporary nginx site is invalid; previous site configuration was restored."
fi

systemctl enable nginx
systemctl restart nginx
ok "Temporary HTTP server is running."

NGINX_ACME_BACKUP="${NGINX_SITE}.acme-working.$(date +%Y%m%d-%H%M%S)"
cp -a "${NGINX_SITE}" "${NGINX_ACME_BACKUP}"

# ------------------------------------------------------------------
# DNS checks
# ------------------------------------------------------------------

log "Checking DNS..."

PUBLIC_IPV4="$(
    curl -4fsS \
        --connect-timeout 5 \
        --max-time 10 \
        https://api.ipify.org \
        2>/dev/null || true
)"

DOMAIN_A="$(dig +short A "${DOMAIN}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)"
DOMAIN_AAAA="$(dig +short AAAA "${DOMAIN}" | sort -u || true)"

echo "Public IPv4: ${PUBLIC_IPV4:-unknown}"
echo "A record(s):"
printf '%s\n' "${DOMAIN_A:-none}"

if [[ -n "${DOMAIN_AAAA}" ]]; then
    echo "AAAA record(s):"
    printf '%s\n' "${DOMAIN_AAAA}"
fi

if [[ -n "${PUBLIC_IPV4}" ]] && grep -Fxq "${PUBLIC_IPV4}" <<<"${DOMAIN_A}"; then
    ok "IPv4 DNS points to this server."
else
    warn "The A record does not appear to point to this server."
    prompt DNS_CONTINUE "Try certificate issuance anyway? [y/N]: "
    [[ "${DNS_CONTINUE:-N}" =~ ^[Yy]$ ]] || die "Fix DNS and rerun the installer."
fi

if [[ -n "${DOMAIN_AAAA}" ]]; then
    LOCAL_V6="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u || true)"
    bad_v6=0

    while IFS= read -r dns_v6; do
        [[ -z "${dns_v6}" ]] && continue

        if ! grep -Fixq "${dns_v6}" <<<"${LOCAL_V6}"; then
            bad_v6=1
        fi
    done <<<"${DOMAIN_AAAA}"

    if (( bad_v6 )); then
        warn "DNS has an AAAA record that was not found on this server."
        warn "Let's Encrypt HTTP-01 validation may fail over IPv6."

        prompt IPV6_CONTINUE "Continue anyway? [y/N]: "
        [[ "${IPV6_CONTINUE:-N}" =~ ^[Yy]$ ]] || die "Fix/remove the incorrect AAAA record and rerun."
    fi
fi

# ------------------------------------------------------------------
# Certificate
# ------------------------------------------------------------------

if [[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]]; then
    ok "Certificate already exists for ${DOMAIN}; reusing it."
else
    log "Obtaining Let's Encrypt certificate for ${DOMAIN}..."

    certbot certonly \
        --webroot \
        --webroot-path "${WEB_ROOT}" \
        --domain "${DOMAIN}" \
        --agree-tos \
        --register-unsafely-without-email \
        --non-interactive
fi

[[ -s "${CERT_DIR}/fullchain.pem" ]] || die "Certificate fullchain.pem is missing."
[[ -s "${CERT_DIR}/privkey.pem" ]] || die "Certificate privkey.pem is missing."

# ------------------------------------------------------------------
# Final nginx site
# ------------------------------------------------------------------

log "Creating final nginx configuration..."

NGINX_SITE_TMP="${NGINX_SITE}.tmp.$$"

cat >"${NGINX_SITE_TMP}" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${DOMAIN};

    root ${WEB_ROOT};

    location /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }

    location / {
        return 301 https://${DOMAIN}\$request_uri;
    }
}

server {
    listen 127.0.0.1:9443 ssl;

    server_name ${DOMAIN};
    server_tokens off;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;

    root ${WEB_ROOT};
    index index.html;

    error_page 404 /404.html;

    location = /404.html {
        internal;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

mv "${NGINX_SITE_TMP}" "${NGINX_SITE}"

if ! nginx -t; then
    cp -a "${NGINX_ACME_BACKUP}" "${NGINX_SITE}"
    nginx -t || true
    die "Final nginx configuration failed validation; the working ACME configuration was restored."
fi

systemctl restart nginx
ok "Final nginx configuration enabled."

# ------------------------------------------------------------------
# Certificate renewal
# ------------------------------------------------------------------

log "Configuring automatic certificate renewal..."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'RENEW_EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

nginx -t
systemctl reload nginx

# Xray/Hysteria2 reads the certificate from the Let's Encrypt mount.
# Restart RemnaNode after a successful renewal so the renewed certificate
# is loaded immediately.
if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq 'remnanode'; then
        docker restart remnanode >/dev/null
    fi
fi
RENEW_EOF

chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if systemctl list-unit-files --type=timer 2>/dev/null | grep -q '^certbot.timer'; then
    systemctl enable --now certbot.timer
    ok "certbot.timer enabled."
else
    warn "certbot.timer was not found; check Certbot renewal scheduling manually."
fi

# ------------------------------------------------------------------
# UFW — LAST, after preserving the real SSH port
# ------------------------------------------------------------------

log "Configuring UFW safely..."

for p in "${SSH_PORTS[@]}"; do
    ufw allow "${p}/tcp"
done

ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow "${REMNA_NODE_PORT}/tcp"

# Verify that at least one detected SSH listener is still present before enabling.
ssh_listener_found=0

for p in "${SSH_PORTS[@]}"; do
    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])${p}$"; then
        ssh_listener_found=1
        break
    fi
done

if (( ! ssh_listener_found )); then
    die "No listening SSH socket was found on the preserved SSH ports. UFW was NOT enabled."
fi

if (( UFW_WAS_ACTIVE )); then
    ok "UFW was already active; rules were updated without restarting it."
else
    ufw --force enable
    ok "UFW enabled. It was not restarted afterwards."
fi

# ------------------------------------------------------------------
# Final checks
# ------------------------------------------------------------------

echo
echo "============================================================"
echo " FINAL CHECK"
echo "============================================================"

echo
echo "[Domain]"
echo "${DOMAIN}"

echo
echo "[SSH ports preserved]"
printf '%s\n' "${SSH_PORTS[@]}"

echo
echo "[RemnaNode API port reserved]"
echo "${REMNA_NODE_PORT}/tcp"

echo
echo "[Hysteria2]"
echo "443/udp allowed"

echo
echo "[BBR]"
sysctl net.core.default_qdisc || true
sysctl net.ipv4.tcp_congestion_control || true
sysctl net.ipv4.ip_forward || true

echo
echo "[Swap]"
swapon --show || true

echo
echo "[UFW]"
ufw status verbose || true

echo
echo "[nginx]"
nginx -t
systemctl is-active nginx || true

echo
echo "[Listening ports]"
ss -lntup || true

echo
echo "[Certificate]"
certbot certificates || true

echo
echo "[Internal HTTPS fallback]"

if curl \
    --silent \
    --show-error \
    --fail \
    --resolve "${DOMAIN}:9443:127.0.0.1" \
    "https://${DOMAIN}:9443/" \
    >/dev/null; then

    echo "127.0.0.1:9443: OK"
else
    echo "127.0.0.1:9443: FAILED"
fi

echo
echo "============================================================"
echo " BASE SYSTEM CONFIGURATION COMPLETED"
echo "============================================================"
echo "Domain: ${DOMAIN}"
echo "Website: ${WEB_ROOT}"
echo "nginx site: ${NGINX_SITE}"
echo "Certificate: ${CERT_DIR}"
echo "Fallback: 127.0.0.1:9443"
echo "RemnaNode API port: ${REMNA_NODE_PORT}/tcp"
echo "Hysteria2 port: 443/udp"

echo
echo "IMPORTANT:"
echo "Keep this SSH session open and test a SECOND SSH connection before logging out."

echo
echo "All nginx / TLS / sysctl / swap / firewall work is finished."
echo "RemnaNode will now be installed as the FINAL step."

echo
echo "The official RemnaNode installer follows Docker logs indefinitely."
echo "After you see that RemnaNode and XRay are up and running, press Ctrl+C."
echo "Ctrl+C at that stage only detaches the live log view; the Docker container"
echo "continues running."
echo "============================================================"

# ------------------------------------------------------------------
# RemnaNode — FINAL STEP
# ------------------------------------------------------------------

log "Downloading RemnaNode installer safely..."

REMNA_TMP="$(mktemp /tmp/remnanode.XXXXXX.sh)"

curl -fL \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 10 \
    "${REMNA_URL}" \
    -o "${REMNA_TMP}"

[[ -s "${REMNA_TMP}" ]] || die "Downloaded RemnaNode installer is empty."

if ! head -n 1 "${REMNA_TMP}" | grep -qE '^#!.*bash'; then
    die "Downloaded RemnaNode installer does not look like a Bash script."
fi

bash -n "${REMNA_TMP}" || die "Downloaded RemnaNode installer failed syntax validation."

echo
echo "============================================================"
echo " STARTING OFFICIAL REMNANODE INSTALLER"
echo "============================================================"
echo "API port is preselected as: ${REMNA_NODE_PORT}"

echo
echo "When installation finishes, the upstream installer will attach to live logs."
echo "Once the node is healthy, press Ctrl+C to leave the log view."
echo "After that this installer will automatically configure Docker for Hysteria2."
echo "============================================================"
echo

# The upstream `install` command intentionally ends in:
#   docker compose ... logs -f
#
# Therefore SIGINT / exit 130 after Ctrl+C is expected and must NOT be
# treated as an installation error by this wrapper.
trap - ERR
set +e

bash "${REMNA_TMP}" @ install --port "${REMNA_NODE_PORT}"
REMNA_RC=$?

set -e

echo

if [[ "${REMNA_RC}" -eq 130 ]]; then
    ok "Detached from RemnaNode live logs with Ctrl+C."
elif [[ "${REMNA_RC}" -ne 0 ]]; then
    printf '\033[1;31m[ERROR]\033[0m RemnaNode installer exited with code %s.\n' "${REMNA_RC}" >&2
    exit "${REMNA_RC}"
else
    ok "RemnaNode installer returned normally."
fi

# ------------------------------------------------------------------
# Hysteria2 Docker configuration
# ------------------------------------------------------------------

configure_remnanode_hysteria

# ------------------------------------------------------------------
# RemnaNode checks
# ------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq 'remnanode'; then
        ok "RemnaNode Docker container is running."
    else
        warn "Could not confirm a running Docker container named 'remnanode'."
        warn "Check with: docker ps"
    fi
fi

if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\])${REMNA_NODE_PORT}$"; then
    ok "TCP port ${REMNA_NODE_PORT} is listening."
else
    warn "TCP port ${REMNA_NODE_PORT} is not currently visible as a host listener."
fi

if ufw status 2>/dev/null | grep -Eq '443/udp[[:space:]]+ALLOW'; then
    ok "UDP port 443 is allowed by UFW."
else
    warn "Could not confirm the UFW allow rule for 443/udp."
fi

echo
echo "============================================================"
echo " INSTALLATION COMPLETED"
echo "============================================================"
echo "Domain: ${DOMAIN}"
echo "RemnaNode API port: ${REMNA_NODE_PORT}/tcp"
echo "Hysteria2 port: 443/udp"
echo "Hysteria2 TLS directory: ${CERT_DIR}"
echo "Docker certificate mount: /etc/letsencrypt:/etc/letsencrypt:ro"
echo "Fallback: 127.0.0.1:9443"

echo
echo "Useful checks:"
echo "  docker ps"
echo "  cd /opt/remnanode && docker compose ps"
echo "  cd /opt/remnanode && docker compose config"
echo "  cd /opt/remnanode && docker compose logs --tail=100"
echo "  docker inspect remnanode --format '{{json .Mounts}}'"
echo "  ss -lunp | grep ':443 '"
echo "  ufw status verbose"
echo "  nginx -t"

echo
echo "Keep the current SSH session open until a second SSH connection succeeds."
echo "============================================================"
