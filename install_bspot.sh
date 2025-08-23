#!/usr/bin/env bash
set -euo pipefail

# Linux-only installer for BSpotDownloader
# - Installs deps via common package managers
# - Installs /usr/local/bin/bspot (self-updating launcher) and alias bspotdownloader
# - Creates user config at ~/.config/bspot/config (prompts only if missing)

# ====== EDIT THESE FOR YOUR REPO ======
GITHUB_OWNER="linux-brat"
GITHUB_REPO="BSpotDownloader"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/master"
# ======================================

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
    say "Could not auto-install packages. Please install manually: $*"
  fi
}

ensure_dep() {
  local cmd="$1" pkg="$2"
  if ! have_cmd "$cmd"; then
    say "Installing dependency: $cmd"
    install_pkg_linux "$pkg" || true
    have_cmd "$cmd" || die "Missing dependency after attempt: $cmd"
  fi
}

ensure_deps() {
  ensure_dep curl curl
  ensure_dep jq jq
  ensure_dep ffmpeg ffmpeg
  # yt-dlp can be from package manager or pip
  if ! have_cmd yt-dlp; then
    say "Installing yt-dlp"
    if have_cmd apt-get; then
      sudo apt-get install -y yt-dlp || true
    elif have_cmd dnf; then
      sudo dnf install -y yt-dlp || true
    elif have_cmd pacman; then
      sudo pacman -Sy --noconfirm yt-dlp || true
    elif have_cmd zypper; then
      sudo zypper install -y yt-dlp || true
    fi
    if ! have_cmd yt-dlp; then
      if have_cmd pipx; then
        pipx install yt-dlp || pipx upgrade yt-dlp || true
      elif have_cmd pip3; then
        pip3 install --user -U yt-dlp
        export PATH="$HOME/.local/bin:$PATH"
      fi
    fi
    have_cmd yt-dlp || die "yt-dlp is required"
  fi
}

write_launcher() {
  local tmp="$(mktemp)"
  cat > "$tmp" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

# Self-updating launcher for BSpotDownloader (Linux)
# Keeps a cached copy in ~/.local/share/bspot and updates it automatically.

OWNER="YOURUSER"
REPO="YOURREPO"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO}/master"

APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
LOCAL_VER_FILE="${APP_HOME}/VERSION"
REMOTE_VER_URL="${RAW_BASE}/VERSION"
REMOTE_SCRIPT_URL="${RAW_BASE}/bspot.sh"

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

# Update policy: always try update if online and remote version differs.
# Set BSPOT_UPDATE=always to force fetch every run even if version same.
UPDATE_POLICY="${BSPOT_UPDATE:-auto}"  # auto|always|never

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

get_remote_version() {
  curl -fsSL "$REMOTE_VER_URL" 2>/dev/null || echo ""
}

get_local_version() {
  [ -f "$LOCAL_VER_FILE" ] && cat "$LOCAL_VER_FILE" || echo ""
}

do_update() {
  mkdir -p "$APP_HOME"
  local tmp_script tmp_ver
  tmp_script="$(mktemp)"
  tmp_ver="$(mktemp)"
  curl -fsSL "$REMOTE_SCRIPT_URL" -o "$tmp_script"
  curl -fsSL "$REMOTE_VER_URL" -o "$tmp_ver"
  chmod +x "$tmp_script"
  mv "$tmp_script" "$APP_SCRIPT"
  mv "$tmp_ver" "$LOCAL_VER_FILE"
}

ensure_latest() {
  mkdir -p "$APP_HOME"
  if [ "$UPDATE_POLICY" = "always" ]; then
    if curl -fsSL "$REMOTE_SCRIPT_URL" >/dev/null 2>&1; then
      do_update || true
    fi
  elif [ "$UPDATE_POLICY" = "never" ]; then
    [ -f "$APP_SCRIPT" ] || do_update
  else
    # auto: compare versions if possible
    local remote localv
    remote="$(get_remote_version || true)"
    localv="$(get_local_version || true)"
    if [ -z "$localv" ] || [ -z "$remote" ] || [ "$remote" != "$localv" ]; then
      if curl -fsSL "$REMOTE_SCRIPT_URL" >/dev/null 2>&1; then
        do_update || true
      fi
    fi
  fi
  [ -f "$APP_SCRIPT" ] || { echo "BSpot main script missing and update failed."; exit 1; }
}

# Ensure config exists but do NOT prompt for credentials here.
# The main script handles first-time setup interactively when needed.
mkdir -p "$CONFIG_DIR"

ensure_latest

exec "$APP_SCRIPT" "$@"
LAUNCHER
  sed -i "s/YOURUSER/${GITHUB_OWNER}/g" "$tmp"
  sed -i "s/YOURREPO/${GITHUB_REPO}/g" "$tmp"
  chmod +x "$tmp"
  $SUDO mv "$tmp" "$LAUNCHER_PATH"
  $SUDO ln -sf "$LAUNCHER_PATH" "$ALIAS_PATH"
  say "Installed launcher: $LAUNCHER_PATH and alias: $ALIAS_PATH"
}

ensure_user_config() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    say "Creating initial config at $CONFIG_FILE"
    read -r -p "Enter Spotify Client ID: " cid
    read -r -p "Enter Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpotDownloader\""
      echo "OUTPUT_EXTENSION=\"mp4\""      # force .mp4 container
      echo "YTDLP_SEARCH_COUNT=\"1\""      # top match by default
      echo "UPDATE_POLICY=\"auto\""        # auto|always|never (used by main script too)
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  else
    say "Config exists; credentials will be reused from: $CONFIG_FILE"
  fi
}

main() {
  need_sudo
  ensure_deps
  write_launcher
  ensure_user_config
  say "Done. Launch with: bspot  (or: bspotdownloader)"
}

main "$@"
