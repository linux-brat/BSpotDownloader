#!/usr/bin/env bash
set -euo pipefail

# BSpot (Spotify-only) — MP3 320k with embedded cover art
# Calm UI (no animations). Simple organization:
#   DOWNLOADS_DIR (default: ~/Downloads/BSpot)
#     ├── Single/
#     │    └── {PrimaryArtist}/Title.mp3
#     └── Playlist/
#          └── {PrimaryArtist}/Title.mp3
#
# Rules:
# - Folder bucket is decided by source type:
#     track  -> Single
#     playlist/album/artist -> Playlist
# - Artist folder uses the first (primary) artist.
# - Filename is just the song Title.mp3 (no artist), as requested.
# - MP3 gets tags: title, artist (all artists joined with "; "), album_artist (primary),
#   album (if known), and embedded cover art when available.
#
# Config lives at ~/.config/bspot/config and is reused (never re-prompted if present).

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

# ================= UI helpers =================
is_tty() { [ -t 1 ]; }
cc() { is_tty && tput setaf "$1" || true; }
cb() { is_tty && tput bold || true; }
cr() { is_tty && tput sgr0 || true; }
bar()  { printf "%s\n" "========================================================"; }
line() { printf "%s\n" "────────────────────────────────────────────────────────"; }

BANNER_TXT=$'██████╗░░██████╗██████╗░░█████╗░████████╗\n██╔══██╗██╔════╝██╔══██╗██╔══██╗╚══██╔══╝\n██████╦╝╚█████╗░██████╔╝██║░░██║░░░██║░░░\n██╔══██╗░╚═══██╗██╔═══╝░██║░░██║░░░██║░░░\n██████╦╝██████╔╝██║░░░░░╚█████╔╝░░░██║░░░\n╚═════╝░╚═════╝░╚═╝░░░░░░╚════╝░░░░╚═╝░░░'

banner_print() { printf "%s\n" "$BANNER_TXT"; }
title() { bar; printf "  %s\n" "$(cb)$(cc 6)$1$(cr)"; bar; }
die(){ echo "$(cc 1)Error:$(cr) $*" >&2; exit 1; }
warn(){ echo "$(cc 3)[warn]$(cr) $*" >&2; }
ok(){   echo "$(cc 2)[ok]$(cr) $*"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
$(cb)$(cc 6)BSpot (Spotify-only)$(cr)

Usage:
  bspot                 Launch menu
  bspot <spotify-url>   Process a Spotify URL directly
  bspot -h | --help     Show help
EOF
}

require_cmds() {
  for c in curl jq yt-dlp ffmpeg; do
    have_cmd "$c" || die "Missing required command: $c"
  done
}

# ================= Config =================
first_time_config() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(cc 6)First-time setup$(cr)"
    read -r -p "Spotify Client ID: " cid
    read -r -p "Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpot\""
      echo "YTDLP_SEARCH_COUNT=\"1\""
      echo "MARKET=\"US\""
      echo "SKIP_EXISTING=\"1\""
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
  : "${MARKET:=US}"
  : "${SKIP_EXISTING:=1}"
}

# ================= Helpers =================
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
  if [[ -z "$type" || -z "$id" || ! "$id" =~ ^[A-Za-z0-9]+$ ]]; then echo "" ""; else echo "$type" "$id"; fi
}

# ================= Network =================
curl_with_status() { curl -sS "$@" -w '\n%{http_code}'; }
expect_json() { echo "$1" | jq -e '.' >/dev/null 2>&1; }
retry_once() { "$@" || { sleep 0.6; "$@"; }; }

spotify_get_token() {
  local id="$1" sec="$2" out http body
  out="$(retry_once curl_with_status -u "${id}:${sec}" -d grant_type=client_credentials https://accounts.spotify.com/api/token)"
  http="$(echo "$out" | tail -n1)"
  body="$(echo "$out" | sed '$d')"
  [ "$http" = "200" ] || die "Spotify auth error ($http): $(echo "$body" | jq -r '.error_description? // .error? // "authorization failed"' 2>/dev/null || echo "authorization failed")"
  expect_json "$body" || die "Spotify auth returned non-JSON"
  echo "$body" | jq -r '.access_token'
}

curl_json() {
  local url="$1" token="$2" out http body
  out="$(retry_once curl_with_status -H "Authorization: Bearer $token" "$url")"
  http="$(echo "$out" | tail -n1)"
  body="$(echo "$out" | sed '$d')"
  if [ "$http" != "200" ]; then
    if expect_json "$body"; then
      local msg; msg="$(echo "$body" | jq -r '.error.message? // .error?.status? // "request failed"')" || msg="request failed"
      die "Spotify API error ($http): $msg ($url)"
    else
      die "Spotify API error ($http) at $url"
    fi
  fi
  expect_json "$body" || die "Invalid JSON from Spotify at $url"
  printf "%s" "$body"
}

# ================= Normalizers (with track_id) =================
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
      duration_ms: .track.duration_ms,
      track_id: .track.id
    }]')"
    items="$(jq -c --argjson a "$items" --argjson b "$part" -n '$a + $b')"
    next="$(echo "$page" | jq -r '.next')"; url="$next"
  done
  echo "$items"
}

fetch_album_tracks() {
  local id="$1" token="$2"
  local meta; meta="$(curl_json "https://api.spotify.com/v1/albums/${id}" "$token")"
  local album_name; album_name="$(echo "$meta" | jq -r '.name')"
  local url="https://api.spotify.com/v1/albums/${id}/tracks?limit=50"
  local items='[]'
  while [ -n "$url" ] && [ "$url" != "null" ]; do
    local page part next
    page="$(curl_json "$url" "$token")"
    part="$(echo "$page" | jq -c --arg an "$album_name" '[.items[]? | {
      title: .name,
      artists: (.artists | map(.name)),
      album: $an,
      duration_ms: .duration_ms,
      track_id: .id
    }]')"
    items="$(jq -c --argjson a "$items" --argjson b "$part" -n '$a + $b')"
    next="$(echo "$page" | jq -r '.next')"; [ "$next" = "null" ] && next=""; url="$next"
  done
  echo "$items"
}

fetch_track() {
  local id="$1" token="$2" page
  page="$(curl_json "https://api.spotify.com/v1/tracks/${id}" "$token")"
  echo "$page" | jq -c '[{
    title: .name,
    artists: (.artists | map(.name)),
    album: .album.name,
    duration_ms: .duration_ms,
    track_id: .id
  }]'
}

fetch_artist_top_tracks() {
  local id="$1" token="$2" market="${3:-US}" page
  page="$(curl_json "https://api.spotify.com/v1/artists/${id}/top-tracks?market=${market}" "$token")"
  echo "$page" | jq -c '[.tracks[]? | {
    title: .name,
    artists: (.artists | map(.name)),
    album: .album.name,
    duration_ms: .duration_ms,
    track_id: .id
  }]'
}

# ================= Cover art =================
get_cover_by_track_id() {
  local track_id="$1" token="$2"
  local body; body="$(curl_json "https://api.spotify.com/v1/tracks/${track_id}" "$token")" || return 0
  echo "$body" | jq -r '.album.images[0].url? // .album.images[1].url? // .album.images[2].url? // empty'
}

download_cover_to_tmp() {
  local url="$1" tmp
  tmp="$(mktemp)"
  if curl -fsSL "$url" -o "$tmp"; then
    echo "$tmp"
  else
    rm -f "$tmp" >/dev/null 2>&1 || true
    echo ""
  fi
}

# ================= Presentation =================
print_tracks() {
  local tracks="$1"
  local n; n="$(echo "$tracks" | jq 'length')"
  echo
  title "Tracks queued: $n"
  echo "$tracks" | jq -r '.[] | "- \(.title) — \((.artists | join(", ")))"'
  bar
}

# Decide bucket by source type; then use primary artist folder; filename is just Title.mp3
build_dest() {
  local type="$1" title="$2" artists="$3" primary="$4"
  local bucket="Playlist"
  case "$type" in
    track) bucket="Single" ;;
    playlist|album|artist) bucket="Playlist" ;;
  esac
  printf "%s/%s/%s/%s\n" \
    "$DOWNLOADS_DIR" \
    "$(sanitize_filename "$bucket")" \
    "$(sanitize_filename "$primary")" \
    "$(sanitize_filename "$title").mp3"
}

# ================= Progress (single calm line) =================
progress_line() {
  local name="$1" line="$2"
  local pct speed eta
  pct="$(sed -n 's/.*\[\s*download\s*\]\s*\([0-9.]\+%\).*/\1/p' <<< "$line" | tail -n1 || true)"
  speed="$(sed -n 's/.*at\s\([0-9.]\+[KMG]iB\/s\).*/\1/p' <<< "$line" | tail -n1 || true)"
  eta="$(sed -n 's/.*ETA\s\([0-9:]\+\).*/\1/p' <<< "$line" | tail -n1 || true)"
  printf "\r$(cc 6)♪$(cr) %s  %s  %s" "$(sanitize_filename "$name")" "${pct:-..%}" "${eta:+ETA $eta}${speed:+  $speed}"
}
clear_progress() { printf "\r%*s\r" 100 ""; }

# ================= Download one (with metadata & cover art) =================
# Args:
# 1 query, 2 dest, 3 title(name), 4 cover_url, 5 full_artists ("; " joined), 6 primary_artist, 7 album_meta
download_one() {
  local query="$1" dest="$2" name="$3" cover_url="$4" full_artists="$5" primary_artist="$6" album_meta="$7"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"
  local tmpl="${parent}/%(title)s.%(ext)s"

  local q1="$query"
  local q2="${query/, / }"
  local cover_file=""

  if [ -n "${cover_url:-}" ]; then
    cover_file="$(download_cover_to_tmp "$cover_url")"
    [ -n "$cover_file" ] || warn "cover fetch failed for: $name"
  fi

  for q in "$q1" "$q2"; do
    if yt-dlp --newline -q --default-search ytsearch -f "bestaudio/best" -o "$tmpl" "ytsearch1:${q}" 2>/dev/null | \
       while IFS= read -r ln; do
         [[ "$ln" == "[download]"* ]] && progress_line "$name" "$ln"
       done
    then
      local latest; latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"
      if [ -n "$latest" ]; then
        clear_progress
        if [ -n "$cover_file" ]; then
          ffmpeg -y -hide_banner -loglevel error \
            -i "$latest" -i "$cover_file" \
            -map 0:a:0 -map 1:v:0 \
            -c:a libmp3lame -b:a 320k \
            -id3v2_version 3 \
            -metadata title="$name" \
            -metadata artist="$full_artists" \
            -metadata album_artist="$primary_artist" \
            ${album_meta:+-metadata album="$album_meta"} \
            -metadata:s:v title="Album cover" \
            -metadata:s:v comment="Cover (front)" \
            -disposition:v attached_pic \
            "$dest"
        else
          ffmpeg -y -hide_banner -loglevel error \
            -i "$latest" \
            -c:a libmp3lame -b:a 320k \
            -id3v2_version 3 \
            -metadata title="$name" \
            -metadata artist="$full_artists" \
            -metadata album_artist="$primary_artist" \
            ${album_meta:+-metadata album="$album_meta"} \
            "$dest"
        fi
        rm -f -- "$latest"; [ -n "$cover_file" ] && rm -f -- "$cover_file"
        ok "$dest"
        return 0
      fi
    fi
  done

  clear_progress
  [ -n "$cover_file" ] && rm -f -- "$cover_file"
  warn "no source matched for: $name"
  return 1
}

# ================= Resolve + run =================
choose_artist_top_n() {
  echo
  echo "Choose artist top-tracks size:"
  echo "  1) Top 10"
  echo "  2) Top 25"
  echo "  3) All"
  printf "%s" "Select [1-3]: "
  read -r sel
  case "$sel" in
    1) echo 10 ;; 2) echo 25 ;; *) echo 1000 ;;
  esac
}

resolve_tracks() {
  local url="$1" type id token out
  read -r type id < <(parse_spotify_type_id "$url")
  [ -n "$type" ] && [ -n "$id" ] || die "Could not parse Spotify ID from URL"
  token="$(spotify_get_token "$SPOTIFY_CLIENT_ID" "$SPOTIFY_CLIENT_SECRET")"
  case "$type" in
    playlist) out="$(fetch_playlist_tracks "$id" "$token")" ;;
    album)    out="$(fetch_album_tracks "$id" "$token")" ;;
    track)    out="$(fetch_track "$id" "$token")" ;;
    artist)   local all topn; all="$(fetch_artist_top_tracks "$id" "$token" "$MARKET")"; topn="$(choose_artist_top_n)"; out="$(echo "$all" | jq -c ".[0:$topn]")" ;;
    *) die "Unsupported Spotify type: $type" ;;
  esac
  echo "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || die "Spotify returned unexpected data."
  printf "%s" "$out"
}

process_spotify_url() {
  local url="$1"
  mkdir -p "$DOWNLOADS_DIR"
  local tracks; tracks="$(resolve_tracks "$url")"
  local len; len="$(echo "$tracks" | jq 'length')"
  [ "$len" -gt 0 ] || die "No tracks found."
  print_tracks "$tracks"

  local type; type="$(parse_spotify_type_id "$url" | awk '{print $1}')"  # track/playlist/album/artist

  printf "%s" "Proceed to download as MP3 320k? [y/N] "
  read -r ans; case "${ans,,}" in y|yes) ;; *) echo "Cancelled."; return 0;; esac

  local token; token="$(spotify_get_token "$SPOTIFY_CLIENT_ID" "$SPOTIFY_CLIENT_SECRET")"

  for i in $(seq 0 $((len-1))); do
    local title artists primary dest name q track_id cover_url album_name full_artists primary_artist

    title="$(echo "$tracks" | jq -r ".[$i].title")"
    artists="$(echo "$tracks" | jq -r ".[$i].artists | join(\", \")")"
    primary="$(echo "$tracks" | jq -r ".[$i].artists[0]")"
    album_name="$(echo "$tracks" | jq -r ".[$i].album // empty")"
    full_artists="$(echo "$tracks" | jq -r ".[$i].artists | join(\"; \")")"
    primary_artist="$primary"

    # destination path based on bucket + artist folder + Title.mp3
    dest="$(build_dest "$type" "$title" "$artists" "$primary")"
    name="$(sanitize_filename "$title")"

    # form search query
    q="${title} ${primary} audio"

    # skip existing
    if [ "$SKIP_EXISTING" = "1" ] && [ -f "$dest" ]; then
      ok "skip (exists): $dest"
      continue
    fi

    # cover art URL (best effort)
    track_id="$(echo "$tracks" | jq -r ".[$i].track_id // empty")"
    cover_url=""; [ -n "$track_id" ] && cover_url="$(get_cover_by_track_id "$track_id" "$token" || echo "")"

    download_one "$q" "$dest" "$name" "$cover_url" "$full_artists" "$primary_artist" "$album_name" \
      || echo "[fail] ${title} — ${artists}" >&2
  done

  ok "Saved under: $DOWNLOADS_DIR"
}

menu() {
  while true; do
    clear || true
    banner_print
    title "BSpot (Spotify-only, MP3 with cover art)"
    echo "  1) Paste a Spotify link"
    echo "  2) Quit"
    line
    printf "%s" "Select: "
    read -r choice
    case "$choice" in
      1) printf "%s" "Paste Spotify URL: "; read -r url; is_spotify "$url" || { warn "Not a Spotify link."; sleep 1; continue; }; process_spotify_url "$url"; printf "%s" "Press Enter to continue..."; read -r _ ;;
      2|q|Q) exit 0 ;;
      -h|--help) usage; printf "%s" "Press Enter to continue..."; read -r _ ;;
      *) warn "Invalid choice"; sleep 0.7 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --uninstall) echo "Run: bspot --uninstall (launcher handles uninstall)"; exit 0 ;;
    *) ;;
  esac
  require_cmds
  first_time_config
  load_config
  if [ $# -gt 0 ]; then
    local url="$1"; is_spotify "$url" || die "This program supports only Spotify URLs."; process_spotify_url "$url"; exit 0
  fi
  menu
}
main "$@"
