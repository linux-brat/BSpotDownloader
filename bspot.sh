#!/usr/bin/env bash
set -euo pipefail

# BSpot (Spotify-only) main app for Linux
# Supports: playlist, album, artist (top tracks), single track
# Output: MP3 (libmp3lame 320k) only
# Config: ~/.config/bspot/config (reused if present; never re-asked)
# Dependencies: curl, jq, ffmpeg, yt-dlp

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

die(){ echo "Error: $*" >&2; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
BSpot (Spotify-only)

Usage:
  bspot                 Launch menu
  bspot <spotify-url>   Process a Spotify URL directly (track/album/playlist/artist)
  bspot -h | --help     Show help

Notes:
- Requires Spotify Client ID/Secret in ${CONFIG_FILE} (first run creates it)
- Downloads MP3 at 320 kbps (searches best matching source)
- Artist: lets you choose Top 10 / Top 25 / All available top tracks
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

load_config() {
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  : "${SPOTIFY_CLIENT_ID:?Missing SPOTIFY_CLIENT_ID in config}"
  : "${SPOTIFY_CLIENT_SECRET:?Missing SPOTIFY_CLIENT_SECRET in config}"
  : "${DOWNLOADS_DIR:?Missing DOWNLOADS_DIR in config}"
  : "${YTDLP_SEARCH_COUNT:=1}"
}

border() { printf "%s\n" "=================================================="; }
title()  { border; printf "  %s\n" "$1"; border; }
prompt() { printf "%s" "$1"; read -r REPLY; }

sanitize_filename() {
  local name="$*"
  name="${name//\//_}"; name="${name//\\/ _}"; name="${name//:/_}"
  name="${name//\*/_}"; name="${name//\?/}"; name="${name//\"/_}"
  name="${name//</_}"; name="${name//>/_}"; name="${name//\|/_}"
  name="$(echo -n "$name" | tr -d '\000-\031')"
  name="$(echo -n "$name" | sed 's/[[:space:]\.]*$//')"
  if [ ${#name} -gt 120 ]; then name="${name:0:120}"; fi
  [ -z "$name" ] && name="untitled"
  printf "%s" "$name"
}

# Entity detection and parsing (supports query/fragment stripping, validates base62 IDs)
is_spotify() { local u="${1,,}"; [[ "$u" == *"open.spotify.com/"* || "$u" == spotify:* ]]; }

parse_spotify_type_id() {
  local url="$1" path type id
  if [[ "$url" == spotify:* ]]; then
    IFS=':' read -r _ type id <<<"$url"
  else
    path="$(printf "%s" "$url" | sed -E 's#https?://open\.spotify\.com/##' | cut -d'?' -f1 | cut -d'#' -f1)"
    type="$(printf "%s" "$path" | awk -F'/' '{print $1}')"
    id="$(printf "%s" "$path" | awk -F'/' '{print $2}')"
  fi
  id="$(printf "%s" "$id" | cut -d'/' -f1)"
  if [[ -z "$type" || -z "$id" || ! "$id" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "" ""
  else
    echo "$type" "$id"
  fi
}

spinner_run() {
  local msg="$1"; shift
  local chars='|/-\' i=0
  printf "%s " "$msg"
  "$@" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf "\r%s %s" "$msg" "${chars:$i:1}"
    sleep 0.1
  done
  wait "$pid"
  printf "\r%*s\r" $(( ${#msg} + 2 )) ""
}

spotify_get_token() {
  local id="$1" sec="$2"
  local body http
  body="$(curl -sS -u "${id}:${sec}" -d grant_type=client_credentials -w '\n%{http_code}' https://accounts.spotify.com/api/token)"
  http="$(echo "$body" | tail -n1)"
  body="$(echo "$body" | sed '$d')"
  if [ "$http" != "200" ]; then
    local msg; msg="$(echo "$body" | jq -r '.error_description? // .error? // "authorization failed"')" || msg="authorization failed"
    die "Spotify auth error ($http): $msg"
  fi
  echo "$body" | jq -r '.access_token'
}

curl_json() {
  local url="$1" token="$2"
  local body http
  body="$(curl -sS -H "Authorization: Bearer $token" -w '\n%{http_code}' "$url")"
  http="$(echo "$body" | tail -n1)"
  body="$(echo "$body" | sed '$d')"
  if [ "$http" != "200" ]; then
    if echo "$body" | jq -e '.' >/dev/null 2>&1; then
      local msg; msg="$(echo "$body" | jq -r '.error.message? // .error?.status? // "request failed"')" || msg="request failed"
      die "Spotify API error ($http): $msg ($url)"
    else
      die "Spotify API error ($http) at $url"
    fi
  fi
  echo "$body"
}

# Fetchers for each entity type
fetch_playlist_tracks() {
  local id="$1" token="$2"
  local url="https://api.spotify.com/v1/playlists/${id}/tracks?limit=100"
  local items='[]'
  while [ -n "$url" ] && [ "$url" != "null" ]; do
    local page part next
    page="$(curl_json "$url" "$token")"
    part="$(echo "$page" | jq -c '[.items[]? | select(.track != null and .track.type == "track") | {
      title: .track.name,
      artists: (.track.artists | map(.name)),
      album: (.track.album.name),
      duration_ms: .track.duration_ms
    }]')"
    items="$(jq -c --argjson a "$items" --argjson b "$part" -n '$a + $b')"
    next="$(echo "$page" | jq -r '.next')"
    url="$next"
  done
  echo "$items"
}

fetch_album_tracks() {
  local id="$1" token="$2"
  local url="https://api.spotify.com/v1/albums/${id}/tracks?limit=50"
  local items='[]'
  while [ -n "$url" ] && [ "$url" != "null" ]; do
    local page part next
    page="$(curl_json "$url" "$token")"
    part="$(echo "$page" | jq -c '[.items[]? | {
      title: .name,
      artists: (.artists | map(.name)),
      album: null,
      duration_ms: .duration_ms
    }]')"
    items="$(jq -c --argjson a "$items" --argjson b "$part" -n '$a + $b')"
    next="$(echo "$page" | jq -r '.next')"
    [ "$next" = "null" ] && next=""
    url="$next"
  done
  echo "$items"
}

fetch_track() {
  local id="$1" token="$2"
  local page
  page="$(curl_json "https://api.spotify.com/v1/tracks/${id}" "$token")"
  echo "$page" | jq -c '[{
    title: .name,
    artists: (.artists | map(.name)),
    album: .album.name,
    duration_ms: .duration_ms
  }]'
}

fetch_artist_top_tracks() {
  local id="$1" token="$2" market="${3:-US}"
  local page
  page="$(curl_json "https://api.spotify.com/v1/artists/${id}/top-tracks?market=${market}" "$token")"
  echo "$page" | jq -c '[.tracks[]? | {
    title: .name,
    artists: (.artists | map(.name)),
    album: .album.name,
    duration_ms: .duration_ms
  }]'
}

print_tracks() {
  local tracks_json="$1"
  local count; count="$(echo "$tracks_json" | jq 'length')"
  echo
  border
  printf " Tracks queued: %s\n" "$count"
  border
  echo "$tracks_json" | jq -r '.[] | " • \(.title) — \((.artists | join(", ")))"'
  border
}

build_dest_path() {
  local folder="$1" title="$2" artists="$3"
  local fdir fname
  fdir="$(sanitize_filename "$folder")"
  fname="$(sanitize_filename "${title} - ${artists}").mp3"
  printf "%s/%s/%s\n" "$DOWNLOADS_DIR" "$fdir" "$fname"
}

ensure_dir(){ mkdir -p "$1"; }

download_search_to_mp3() {
  local query="$1" dest="$2"
  local parent; parent="$(dirname "$dest")"
  ensure_dir "$parent"
  local tmpl="${parent}/%(title)s.%(ext)s"
  yt-dlp -q -f "bestaudio/best" -o "$tmpl" "ytsearch1:${query}"
  local latest; latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"
  if [ -z "$latest" ]; then echo "[warn] nothing downloaded for: $query" >&2; return 1; fi
  ffmpeg -y -hide_banner -loglevel error -i "$latest" -vn -c:a libmp3lame -b:a 320k "$dest"
  rm -f -- "$latest"
  echo "[ok] $dest"
}

choose_artist_top_n() {
  echo
  echo "Pick artist top-tracks size:"
  echo "  1) Top 10"
  echo "  2) Top 25"
  echo "  3) All available"
  prompt "Select [1-3]: "
  case "$REPLY" in
    1) echo 10 ;;
    2) echo 25 ;;
    *) echo 1000 ;; # effectively "all"
  esac
}

resolve_spotify_tracks() {
  local url="$1"
  local type id token
  read -r type id < <(parse_spotify_type_id "$url")
  if [ -z "$type" ] || [ -z "$id" ]; then
    die "Could not parse a valid Spotify ID from the URL. Ensure it’s a public playlist/album/track/artist link."
  fi
  token="$(spotify_get_token "$SPOTIFY_CLIENT_ID" "$SPOTIFY_CLIENT_SECRET")"
  [ -n "$token" ] || die "Failed to obtain Spotify token"

  case "$type" in
    playlist)
      fetch_playlist_tracks "$id" "$token"
      ;;
    album)
      fetch_album_tracks "$id" "$token"
      ;;
    track)
      fetch_track "$id" "$token"
      ;;
    artist)
      # Fetch top tracks and trim to selection
      local all topn
      all="$(fetch_artist_top_tracks "$id" "$token")"
      topn="$(choose_artist_top_n)"
      echo "$all" | jq -c ".[0:$topn]"
      ;;
    *)
      die "Unsupported Spotify type: $type (supported: playlist, album, track, artist)"
      ;;
  esac
}

process_spotify_url() {
  local url="$1"
  mkdir -p "$DOWNLOADS_DIR"

  # Show loader and resolve
  local tracks; tracks="$(spinner_run "Loading from Spotify…" resolve_spotify_tracks "$url")"
  if ! echo "$tracks" | jq -e 'type=="array"' >/dev/null 2>&1; then
    die "Invalid response from Spotify (not JSON array)."
  fi
  local len; len="$(echo "$tracks" | jq 'length')"
  [ "$len" -gt 0 ] || die "No tracks found. If this is a private resource, client-credentials cannot read it."

  print_tracks "$tracks"

  # Decide folder label
  local type; type="$(parse_spotify_type_id "$url" | awk '{print $1}')"
  local folder="Playlist"
  case "$type" in
    album)  folder="Album" ;;
    track)  folder="Single" ;;
    artist) folder="ArtistTop" ;;
  esac

  prompt "Proceed to download all as MP3 320k? [y/N] "
  case "${REPLY,,}" in y|yes) ;; *) echo "Cancelled."; return 0;; esac

  for i in $(seq 0 $((len-1))); do
    local title joined primary q dest
    title="$(echo "$tracks" | jq -r ".[$i].title")"
    joined="$(echo "$tracks" | jq -r ".[$i].artists | join(\", \")")"
    primary="$(echo "$tracks" | jq -r ".[$i].artists[0]")"
    q="${title} ${primary} audio"
    dest="$(build_dest_path "$folder" "$title" "$joined")"
    if [ -f "$dest" ]; then
      echo "[skip] $dest"
      continue
    fi
    download_search_to_mp3 "$q" "$dest" || echo "[fail] ${title} — ${joined}" >&2
  done
  echo "Saved under: $DOWNLOADS_DIR/$folder"
}

menu() {
  while true; do
    clear || true
    title "BSpot (Spotify-only, MP3)"
    echo "  1) Paste a Spotify link (track/album/playlist/artist)"
    echo "  2) Quit"
    border
    prompt "Select: "
    case "$REPLY" in
      1) prompt "Paste Spotify URL: "; local url="$REPLY"; is_spotify "$url" || { echo "Not a Spotify link."; sleep 1; continue; }; process_spotify_url "$url"; prompt "Press Enter to continue...";;
      2|q|Q) exit 0 ;;
      -h|--help) usage; prompt "Press Enter to continue...";;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --uninstall) echo "Run: bspot --uninstall (handled by launcher)"; exit 0 ;;
    *) ;;
  esac
  require_cmds
  first_time_config
  load_config
  if [ $# -gt 0 ]; then
    local url="$1"
    is_spotify "$url" || die "This program supports only Spotify URLs."
    process_spotify_url "$url"
    exit 0
  fi
  menu
}
main "$@"
