#!/usr/bin/env bash
set -euo pipefail

# BSpotDownloader main app (Linux)
# - YouTube: choose MP4 video quality (Best, 4K, 2K, 1080p, 720p, 480p)
# - Non-YouTube (incl. Spotify-resolved): MP3 audio-only 320k
# - Persistent config reused automatically

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"
APP_HOME="${HOME}/.local/share/bspot"

die(){ echo "Error: $*" >&2; exit 1; }
say(){ echo "[*] $*"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
BSpotDownloader (Linux)

Usage:
  bspot                 Launch menu
  bspot <url>           Process a single URL directly
  bspot -h | --help     Show help
  bspot --uninstall     Uninstall (handled by launcher)

Rules:
  - YouTube links: MP4 video at chosen quality (Best/4K/2K/1080p/720p/480p)
  - Other links & Spotify-resolved: MP3 audio-only 320k, saved under ~/Downloads/BSpotDownloader
EOF
}

require_cmds() {
  for c in curl jq yt-dlp ffmpeg; do
    have_cmd "$c" || die "Missing required command: $c"
  done
}

first_time_config() {
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
    echo "[ok] Config saved: $CONFIG_FILE"
  fi
}

load_config() {
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${SPOTIFY_CLIENT_ID:?Missing SPOTIFY_CLIENT_ID in config}"
  : "${SPOTIFY_CLIENT_SECRET:?Missing SPOTIFY_CLIENT_SECRET in config}"
  : "${DOWNLOADS_DIR:?Missing DOWNLOADS_DIR in config}"
  : "${YTDLP_SEARCH_COUNT:=1}"
}

border() { printf "%s\n" "=============================================="; }
title()  { border; printf "  %s\n" "$1"; border; }
prompt() { printf "%s" "$1"; read -r REPLY; }

sanitize_filename() {
  local name="$*"
  name="${name//\//_}"
  name="${name//\\/ _}"
  name="${name//:/_}"
  name="${name//\*/_}"
  name="${name//\?/}"
  name="${name//\"/_}"
  name="${name//</_}"
  name="${name//>/_}"
  name="${name//\|/_}"
  name="$(echo -n "$name" | tr -d '\000-\031')"
  name="$(echo -n "$name" | sed 's/[[:space:]\.]*$//')"
  if [ ${#name} -gt 120 ]; then name="${name:0:120}"; fi
  [ -z "$name" ] && name="untitled"
  printf "%s" "$name"
}

is_spotify() { local u="${1,,}"; [[ "$u" == *"open.spotify.com/"* || "$u" == spotify:* ]]; }
is_youtube() { local u="${1,,}"; [[ "$u" == *"youtube.com/"* || "$u" == *"youtu.be/"* ]]; }

spotify_parse_type_id() {
  local url="$1"
  if [[ "$url" == spotify:* ]]; then IFS=':' read -r _ type id <<<"$url"; echo "$type" "$id"; return; fi
  local path; path="$(echo "$url" | sed -E 's#https?://open\.spotify\.com/##' | cut -d'?' -f1)"
  local type id; type="$(echo "$path" | cut -d'/' -f1)"; id="$(echo "$path" | cut -d'/' -f2)"
  echo "$type" "$id"
}

spotify_token() {
  local id="$1" sec="$2"
  curl -sS -u "${id}:${sec}" -d grant_type=client_credentials \
    https://accounts.spotify.com/api/token | jq -r '.access_token'
}

spotify_get_tracks_json() {
  local type="$1" id="$2" token="$3"
  case "$type" in
    playlist)
      local url="https://api.spotify.com/v1/playlists/${id}/tracks?limit=100"
      local items="[]"
      while [ -n "$url" ] && [ "$url" != "null" ]; do
        local page; page="$(curl -sS -H "Authorization: Bearer $token" "$url")"
        local part; part="$(echo "$page" | jq -c '[.items[]? | select(.track != null and .track.type == "track") | {
          title: .track.name,
          artists: (.track.artists | map(.name)),
          album: (.track.album.name),
          duration_ms: .track.duration_ms
        }]')"
        items="$(jq -c --argjson a "$items" --argjson b "$part" -n '$a + $b')"
        url="$(echo "$page" | jq -r '.next')"
      done
      echo "$items"
      ;;
    album)
      local url="https://api.spotify.com/v1/albums/${id}/tracks?limit=50"
      local tracks="[]"
      while [ -n "$url" ] && [ "$url" != "null" ]; do
        local page; page="$(curl -sS -H "Authorization: Bearer $token" "$url")"
        local items; items="$(echo "$page" | jq -c '[.items[]? | {
          title: .name,
          artists: (.artists | map(.name)),
          album: null,
          duration_ms: .duration_ms
        }]')"
        tracks="$(jq -c --argjson a "$tracks" --argjson b "$items" -n '$a + $b')"
        url="$(echo "$page" | jq -r '.next')"
        [ "$url" = "null" ] && url=""
      done
      echo "$tracks"
      ;;
    track)
      local tjson; tjson="$(curl -sS -H "Authorization: Bearer $token" "https://api.spotify.com/v1/tracks/${id}")"
      echo "$tjson" | jq -c '[{
        title: .name,
        artists: (.artists | map(.name)),
        album: .album.name,
        duration_ms: .duration_ms
      }]'
      ;;
    *) die "Unsupported Spotify type: $type" ;;
  esac
}

print_tracks() {
  local tracks_json="$1"
  local count; count="$(echo "$tracks_json" | jq 'length')"
  echo
  border
  printf " Tracks: %s\n" "$count"
  border
  echo "$tracks_json" | jq -r '.[] | " • " + .title + " — " + (.artists | join(", "))"'
  border
}

build_dest_path() {
  local folder="$1" title="$2" artists="$3" ext="$4"
  local fdir="$(sanitize_filename "$folder")"
  local fname="$(sanitize_filename "${title} - ${artists}").${ext}"
  printf "%s/%s/%s\n" "$DOWNLOADS_DIR" "$fdir" "$fname"
}

ensure_dir(){ mkdir -p "$1"; }

# -------- YouTube video quality handling --------
yt_quality_menu() {
  border
  echo "Choose MP4 video quality:"
  echo "  1) Best available"
  echo "  2) 4K (2160p)"
  echo "  3) 2K (1440p)"
  echo "  4) 1080p"
  echo "  5) 720p"
  echo "  6) 480p"
  border
  prompt "Select [1-6]: "
  case "$REPLY" in
    1) echo "bestvideo*[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" ;;
    2) echo "bestvideo[height<=2160][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=2160]+bestaudio/best" ;;
    3) echo "bestvideo[height<=1440][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1440]+bestaudio/best" ;;
    4) echo "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best" ;;
    5) echo "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best" ;;
    6) echo "bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=480]+bestaudio/best" ;;
    *) echo "bestvideo*[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" ;;
  esac
}

download_youtube_mp4_with_quality() {
  local url="$1" outdir="$2" format_selector="$3"
  ensure_dir "$outdir"
  local tmpl="${outdir}/%(title)s.%(ext)s"
  echo "[yt] Format: $format_selector"
  yt-dlp -o "$tmpl" -f "$format_selector" --merge-output-format mp4 "$url"
  echo "[ok] Saved to: $outdir"
}

# -------- Audio-only (search or direct) --------
download_search_to_mp3() {
  local query="$1" dest="$2"
  local parent; parent="$(dirname "$dest")"
  ensure_dir "$parent"
  local tmpl="${parent}/%(title)s.%(ext)s"
  echo "[dl] $query -> .mp3"
  yt-dlp -q -f "bestaudio/best" -o "$tmpl" "ytsearch1:${query}"
  local latest; latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"
  if [ -z "$latest" ]; then echo "Warning: nothing downloaded for: $query" >&2; return 1; fi
  ffmpeg -y -hide_banner -loglevel error -i "$latest" -vn -c:a libmp3lame -b:a 320k "$dest"
  rm -f -- "$latest"
  echo "[ok] $dest"
}

download_direct_to_mp3() {
  local url="$1" outdir="$2"
  ensure_dir "$outdir"
  local tmpl="${outdir}/%(title)s.%(ext)s"
  echo "[dl] Direct (MP3): $url"
  yt-dlp -f "bestaudio/best" -o "$tmpl" "$url"
  shopt -s nullglob
  for src in "$outdir"/*; do
    local base name dest
    base="$(basename "$src")"; name="${base%.*}"; dest="${outdir}/$(sanitize_filename "$name").mp3"
    ffmpeg -y -hide_banner -loglevel error -i "$src" -vn -c:a libmp3lame -b:a 320k "$dest"
    rm -f -- "$src"
    echo "[ok] $dest"
  done
}

process_url() {
  local url="$1"
  mkdir -p "$DOWNLOADS_DIR"

  if is_youtube "$url"; then
    local fmt outdir
    fmt="$(yt_quality_menu)"
    outdir="${DOWNLOADS_DIR}/YouTube"
    download_youtube_mp4_with_quality "$url" "$outdir" "$fmt"
    echo "[done] Saved under: $outdir"
    return 0
  fi

  if is_spotify "$url"; then
    local type id token
    read -r type id < <(spotify_parse_type_id "$url")
    [ -n "$type" ] && [ -n "$id" ] || die "Failed to parse Spotify URL/URI"

    token="$(spotify_token "$SPOTIFY_CLIENT_ID" "$SPOTIFY_CLIENT_SECRET")"
    [ -n "$token" ] || die "Failed to obtain Spotify token"

    local tracks
    tracks="$(spotify_get_tracks_json "$type" "$id" "$token")"
    local len; len="$(echo "$tracks" | jq 'length')"
    [ "$len" -gt 0 ] || die "No tracks found."

    print_tracks "$tracks"
    prompt "Download all as MP3? [y/N] "; case "${REPLY,,}" in y|yes) ;; *) echo "Cancelled."; return 0;; esac

    local folder="Playlist"; case "$type" in album) folder="Album" ;; track) folder="Single" ;; esac
    for i in $(seq 0 $((len-1))); do
      local title joined primary q dest
      title="$(echo "$tracks" | jq -r ".[$i].title")"
      joined="$(echo "$tracks" | jq -r ".[$i].artists | join(\", \")")"
      primary="$(echo "$tracks" | jq -r ".[$i].artists[0]")"
      q="${title} ${primary} audio"
      dest="$(build_dest_path "$folder" "$title" "$joined" "mp3")"
      [ -f "$dest" ] && { echo "[skip] $dest"; continue; }
      download_search_to_mp3 "$q" "$dest" || echo "[fail] ${title} — ${joined}" >&2
    done
    echo "[done] Saved under: $DOWNLOADS_DIR/$folder"
  else
    local outdir="${DOWNLOADS_DIR}/Direct"
    download_direct_to_mp3 "$url" "$outdir"
    echo "[done] Saved under: $outdir"
  fi
}

menu() {
  while true; do
    clear || true
    title "BSpotDownloader (Linux)"
    echo "  1) Paste a link to process"
    echo "  2) Quit"
    border
    prompt "Select: "
    case "$REPLY" in
      1) prompt "Paste Spotify/YouTube/etc. URL: "; process_url "$REPLY"; prompt "Press Enter to continue...";;
      2|q|Q) exit 0 ;;
      -h|--help) usage; prompt "Press Enter to continue...";;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --uninstall) echo "Please run: bspot --uninstall (handled by launcher)"; exit 0 ;;
    *) ;;
  esac

  require_cmds
  first_time_config
  load_config

  if [ $# -gt 0 ]; then
    process_url "$1"
    exit 0
  fi

  menu
}

main "$@"
