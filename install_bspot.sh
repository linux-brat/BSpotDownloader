#!/usr/bin/env bash
set -euo pipefail

# Linux-only installer for BSpotDownloader
# - Cleans previous install (launcher + local cache)
# - Installs dependencies if missing
# - Installs self-updating launcher and preserves user config

# ====== REPO SETTINGS ======
GITHUB_OWNER="linux-brat"
GITHUB_REPO="BSpotDownloader"
DEFAULT_BRANCH="master"   # change to "main" if repo default changes
# ===========================

# Paths
BIN_DIR="/usr/local/bin"
LAUNCHER_PATH="${BIN_DIR}/bspot"
ALIAS_PATH="${BIN_DIR}/bspotdownloader"
APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
APP_VERSION_FILE="${APP_HOME}/VERSION"
CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

die(){ echo "Error: $*" >&2; exit 1; }
say(){ echo "[*] $*"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_sudo() {
  if [ ! -w "$BIN_DIR" ]; then
    have_cmd sudo || die "sudo is required to write to ${BIN_DIR}"
    SUDO="sudo"
  else
    SUDO=""
  fi
}

install_pkg_linux() {
  if have_cmd apt-get; then
    sudo apt-get update -y
    sudo apt-get install -y "$@"
  elif have_cmd dnf; then
    sudo dnf install -y "$@"
  elif have_cmd yum; then
    sudo yum install -y "$@"
  elif have_cmd pacman; then
    sudo pacman -Sy --noconfirm "$@"
  elif have_cmd zypper; then
    sudo zypper install -y "$@"
  else
    say "Auto install not supported; please install manually: $*"
  fi
}

ensure_dep() {
  local cmd="$1" pkg="$2"
  if ! have_cmd "$cmd"; then
    say "Installing: $cmd"
    install_pkg_linux "$pkg" || true
    have_cmd "$cmd" || die "Missing dependency: $cmd"
  fi
}

ensure_deps() {
  ensure_dep curl curl
  ensure_dep jq jq
  ensure_dep ffmpeg ffmpeg
  if ! have_cmd yt-dlp; then
    say "Installing yt-dlp"
    if have_cmd apt-get; then sudo apt-get install -y yt-dlp || true
    elif have_cmd dnf; then sudo dnf install -y yt-dlp || true
    elif have_cmd pacman; then sudo pacman -Sy --noconfirm yt-dlp || true
    elif have_cmd zypper; then sudo zypper install -y yt-dlp || true
    fi
    if ! have_cmd yt-dlp; then
      if have_cmd pipx; then pipx install yt-dlp || pipx upgrade yt-dlp || true
      elif have_cmd pip3; then pip3 install --user -U yt-dlp; export PATH="$HOME/.local/bin:$PATH"
      fi
    fi
    have_cmd yt-dlp || die "yt-dlp is required"
  fi
}

cleanup_old() {
  say "Cleaning previous install (safe)…"
  rm -f "${APP_SCRIPT}" "${APP_VERSION_FILE}" 2>/dev/null || true
  $SUDO rm -f "${LAUNCHER_PATH}" "${ALIAS_PATH}" 2>/dev/null || true
}

write_launcher() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

# BSpotDownloader self-updating launcher (Linux)

OWNER="linux-brat"
REPO="BSpotDownloader"
BRANCH_PREFERRED="master"
BRANCH_FALLBACK="main"

RAW_BASE_PREF="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH_PREFERRED}"
RAW_BASE_FALL="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH_FALLBACK}"

APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
LOCAL_VER_FILE="${APP_HOME}/VERSION"

CONFIG_DIR="${HOME}/.config/bspot"
mkdir -p "$CONFIG_DIR"

pick_raw_base() {
  if curl -fsSL "${RAW_BASE_PREF}/bspot.sh" >/dev/null 2>&1 && curl -fsSL "${RAW_BASE_PREF}/VERSION" >/dev/null 2>&1; then
    echo "$RAW_BASE_PREF"
  elif curl -fsSL "${RAW_BASE_FALL}/bspot.sh" >/dev/null 2>&1 && curl -fsSL "${RAW_BASE_FALL}/VERSION" >/dev/null 2>&1; then
    echo "$RAW_BASE_FALL"
  else
    echo ""
  fi
}

do_update() {
  local base="$1"
  mkdir -p "$APP_HOME"
  local ts tv
  ts="$(mktemp)"; tv="$(mktemp)"
  curl -fsSL "${base}/bspot.sh" -o "$ts"
  curl -fsSL "${base}/VERSION" -o "$tv"
  chmod +x "$ts"
  mv "$ts" "$APP_SCRIPT"
  mv "$tv" "$LOCAL_VER_FILE"
}

ensure_latest() {
  mkdir -p "$APP_HOME"
  local base; base="$(pick_raw_base)"
  if [ -z "$base" ]; then
    echo "Cannot fetch BSpotDownloader (checked: ${RAW_BASE_PREF} and ${RAW_BASE_FALL}) and no local copy found."
    exit 1
  fi
  # Always update (since install cleans cache). You can change to version-compare if desired.
  do_update "$base" || true
  [ -f "$APP_SCRIPT" ] || { echo "BSpot main script missing."; exit 1; }
}

ensure_latest
exec "$APP_SCRIPT" "$@"
LAUNCHER
  sed -i "s/linux-brat/${GITHUB_OWNER}/g" "$tmp"
  sed -i "s/BSpotDownloader/${GITHUB_REPO}/g" "$tmp"
  sed -i "s/BRANCH_PREFERRED=\"master\"/BRANCH_PREFERRED=\"${DEFAULT_BRANCH}\"/" "$tmp"
  chmod +x "$tmp"
  $SUDO mv "$tmp" "$LAUNCHER_PATH"
  $SUDO ln -sf "$LAUNCHER_PATH" "$ALIAS_PATH"
  say "Installed launcher: $LAUNCHER_PATH (alias: $ALIAS_PATH)"
}

ensure_user_config() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "=== BSpotDownloader first-time setup ==="
    read -r -p "Spotify Client ID: " cid
    read -r -p "Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpotDownloader\""
      echo "YTDLP_SEARCH_COUNT=\"1\""
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    say "Saved: $CONFIG_FILE"
  else
    say "Using existing config: $CONFIG_FILE"
  fi
}

main() {
  need_sudo
  ensure_deps
  cleanup_old
  write_launcher
  ensure_user_config
  say "Done. Run: bspot"
}

main "$@"
