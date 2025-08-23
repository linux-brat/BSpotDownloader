#!/usr/bin/env bash
set -euo pipefail

# BSpot (Spotify-only) installer for Linux
# - Cleans previous install (launcher + local cache) silently
# - Installs dependencies if missing
# - Installs launcher that always fetches latest bspot.sh from master
# - Preserves ~/.config/bspot/config

# Change this to your repo path if different:
RAW_SCRIPT_URL="https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master/bspot.sh"

BIN_DIR="/usr/local/bin"
LAUNCHER_PATH="${BIN_DIR}/bspot"
APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

have_cmd(){ command -v "$1" >/dev/null 2>&1; }
die(){ echo "Error: $*" >&2; exit 1; }

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
    sudo apt-get update -y >/dev/null
    sudo apt-get install -y "$@" >/dev/null
  elif have_cmd dnf; then
    sudo dnf install -y -q "$@"
  elif have_cmd yum; then
    sudo yum install -y -q "$@"
  elif have_cmd pacman; then
    sudo pacman -Sy --noconfirm "$@" >/dev/null
  elif have_cmd zypper; then
    sudo zypper install -y "$@" >/dev/null
  else
    die "Please install packages manually: $*"
  fi
}

ensure_dep() {
  local cmd="$1" pkg="$2"
  have_cmd "$cmd" || install_pkg_linux "$pkg"
  have_cmd "$cmd" || die "Missing dependency: $cmd"
}

ensure_deps() {
  ensure_dep curl curl
  ensure_dep jq jq
  ensure_dep ffmpeg ffmpeg
  if ! have_cmd yt-dlp; then
    if have_cmd apt-get; then sudo apt-get install -y yt-dlp >/dev/null || true
    elif have_cmd dnf; then sudo dnf install -y -q yt-dlp || true
    elif have_cmd pacman; then sudo pacman -Sy --noconfirm yt-dlp >/dev/null || true
    elif have_cmd zypper; then sudo zypper install -y yt-dlp >/dev/null || true
    fi
    if ! have_cmd yt-dlp; then
      if have_cmd pipx; then pipx install yt-dlp >/dev/null || pipx upgrade yt-dlp >/dev/null || true
      elif have_cmd pip3; then pip3 install --user -U yt-dlp >/dev/null; export PATH="$HOME/.local/bin:$PATH"
      fi
    fi
    have_cmd yt-dlp || die "yt-dlp is required"
  fi
}

cleanup_old() {
  rm -f "${APP_SCRIPT}" 2>/dev/null || true
  $SUDO rm -f "${LAUNCHER_PATH}" 2>/dev/null || true
}

write_launcher() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

# BSpot (Spotify-only) launcher for Linux — fixed raw URL (master)
RAW_SCRIPT_URL="https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master/bspot.sh"

APP_HOME="${HOME}/.local/share/bspot"
APP_SCRIPT="${APP_HOME}/bspot.sh"
CONFIG_DIR="${HOME}/.config/bspot"

spinner() {
  local pid="$1" msg="$2" chars='|/-\' i=0
  printf "%s " "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf "\r%s %s" "$msg" "${chars:$i:1}"
    sleep 0.1
  done
  printf "\r%*s\r" $(( ${#msg} + 2 )) ""
}

fetch_fresh() {
  mkdir -p "$APP_HOME"
  local ts; ts="$(mktemp)"
  ( curl -fsSL "$RAW_SCRIPT_URL" -o "$ts" ) &
  local cpid=$!
  spinner "$cpid" "Updating BSpot"
  wait "$cpid" || { echo "Cannot fetch: $RAW_SCRIPT_URL"; exit 1; }
  chmod +x "$ts"
  mv "$ts" "$APP_SCRIPT"
}

usage() {
  cat <<EOF
BSpot (Spotify-only) launcher

Usage:
  bspot                 Launch the app menu
  bspot <spotify-url>   Process a single Spotify URL directly
  bspot --uninstall     Remove launcher and cache; ask to remove config
  bspot -h | --help     Show help
EOF
}

cmd_uninstall() {
  echo "Uninstalling BSpot…"
  if [ -w "/usr/local/bin" ]; then SUDO=""; else command -v sudo >/dev/null 2>&1 && SUDO="sudo" || SUDO=""; fi
  $SUDO rm -f /usr/local/bin/bspot 2>/dev/null || true
  rm -rf "$APP_HOME"
  if [ -d "$CONFIG_DIR" ]; then
    read -r -p "Remove user config at $CONFIG_DIR? [y/N] " ans
    case "${ans,,}" in y|yes) rm -rf "$CONFIG_DIR"; echo "Config removed." ;; *) echo "Config kept." ;; esac
  fi
  echo "Uninstalled."
  exit 0
}

main() {
  mkdir -p "$CONFIG_DIR" "$APP_HOME"
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --uninstall) cmd_uninstall ;;
    *) ;;
  esac
  fetch_fresh
  exec "$APP_SCRIPT" "$@"
}
main "$@"
LAUNCHER
  chmod +x "$tmp"
  $SUDO mv "$tmp" "$LAUNCHER_PATH"
}

ensure_user_config() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    # single, first-time prompt (never prompted again if file exists)
    read -r -p "Spotify Client ID: " cid
    read -r -p "Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpot\""
      echo "YTDLP_SEARCH_COUNT=\"1\""
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  fi
}

main() {
  need_sudo
  ensure_deps
  cleanup_old
  write_launcher
  ensure_user_config
  echo "Done. Run: bspot"
}
main "$@"
