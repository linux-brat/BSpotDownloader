#!/usr/bin/env bash
set -euo pipefail

# BSpot (Spotify-only) with rich progress UI
# - Entities: playlist, album, track, artist(top tracks)
# - Output: MP3 320 kbps
# - Live progress: percent, speed, ETA, downloaded, rate
# - Features: preview-only mode, skip/resume, limited concurrency, retries
# - Config: ~/.config/bspot/config (reused; never re-asked if present)

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

# ---------- UI helpers ----------
is_tty() { [ -t 1 ]; }
cc() { is_tty && tput setaf "$1" || true; }
cb() { is_tty && tput bold || true; }
cr() { is_tty && tput sgr0 || true; }
line() { printf "%s\n" "────────────────────────────────────────────────────────"; }
bar()  { printf "%s\n" "========================================================"; }
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

Tips:
- Public Spotify resources only (client credentials). Private playlists require user OAuth (not implemented here).
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
    echo "$(cc 6)First-time setup$(cr)"
    read -r -p "Spotify Client ID: " cid
    read -r -p "Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpot\""
      echo "YTDLP_SEARCH_COUNT=\"1\""
      echo "MARKET=\"US\""
      echo "SKIP_EXISTING=\"1\""           # 1=skip existing files
      echo "CONCURRENCY=\"2\""            # 1..3
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
  : "${CONCURRENCY:=2}"
  [[ "$CONCURRENCY" =~ ^[1-3]$ ]] || CONCURRENCY=2
}

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
  if [[ -z "$type" || -z "$id" || ! "$id" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "" ""
  else
    echo "$type" "$id"
  fi
}

# ---------- Network helpers ----------
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

# ---------- Spotify -> normalized tracks array ----------
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
  local id="$1" token="$2" page
  page="$(curl_json "https://api.spotify.com/v1/tracks/${id}" "$token")"
  echo "$page" | jq -c '[{
    title: .name,
    artists: (.artists | map(.name)),
    album: .album.name,
    duration_ms: .duration_ms
  }]'
}

fetch_artist_top_tracks() {
  local id="$1" token="$2" market="${3:-US}" page
  page="$(curl_json "https://api.spotify.com/v1/artists/${id}/top-tracks?market=${market}" "$token")"
  echo "$page" | jq -c '[.tracks[]? | {
    title: .name,
    artists: (.artists | map(.name)),
    album: .album.name,
    duration_ms: .duration_ms
  }]'
}

# ---------- Presentation ----------
print_tracks() {
  local tracks="$1"
  local n; n="$(echo "$tracks" | jq 'length')"
  echo
  title "Tracks queued: $n"
  echo "$tracks" | jq -r '.[] | "- \(.title) — \((.artists | join(", ")))"'
  bar
}

# ---------- Download engine with live progress ----------
# Parse yt-dlp progress lines like:
# [download]   5.3% of 3.45MiB at 251.55KiB/s ETA 00:12
render_progress() {
  local name="$1" line="$2"
  local pct size speed eta
  pct="$(sed -n 's/.*\[\s*download\s*\]\s*\([0-9.]\+%\).*/\1/p' <<< "$line" | tail -n1 || true)"
  size="$(sed -n 's/.*of\s\([0-9.]\+[KMG]iB\).*/\1/p' <<< "$line" | tail -n1 || true)"
  speed="$(sed -n 's/.*at\s\([0-9.]\+[KMG]iB\/s\).*/\1/p' <<< "$line" | tail -n1 || true)"
  eta="$(sed -n 's/.*ETA\s\([0-9:]\+\).*/\1/p' <<< "$line" | tail -n1 || true)"
  local pbar
  if [[ "$pct" =~ ^([0-9]+) ]]; then
    local p="${BASH_REMATCH[1]}"
    local w=28 filled=$(( p * w / 100 )) empty=$(( w - filled ))
    pbar="$(printf "%0.s#" $(seq 1 $filled))$(printf "%0.s-" $(seq 1 $empty))"
  else
    pbar="----------------------------"
  fi
  printf "\r$(cc 6)[%s]$(cr) [%s] %s %s %s" "$name" "$pbar" "${pct:-..%}" "${speed:-.../s}" "${eta:+ETA $eta}"
}

download_one() {
  local query="$1" dest="$2" name="$3"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"
  local tmpl="${parent}/%(title)s.%(ext)s"

  # Try up to 2 searches: (title + first artist) then (title + all artists)
  local q1="$query"
  local q2="${query/, / }"

  for q in "$q1" "$q2"; do
    # use --newline to stream progress
    if yt-dlp --newline -q --default-search ytsearch -f "bestaudio/best" -o "$tmpl" "ytsearch1:${q}" 2>/dev/null | while IFS= read -r ln; do
         if [[ "$ln" == "[download]"* ]]; then render_progress "$name" "$ln"; fi
       done
    then
      # pick newest file and convert to mp3
      local latest; latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"
      if [ -n "$latest" ]; then
        printf "\r%*s\r" 100 ""
        ffmpeg -y -hide_banner -loglevel error -i "$latest" -vn -c:a libmp3lame -b:a 320k "$dest"
        rm -f -- "$latest"
        ok "$dest"
        return 0
      fi
    fi
  done

  printf "\r%*s\r" 100 ""
  warn "no source matched for: $name"
  return 1
}

build_dest() {
  local folder="$1" title="$2" artists="$3"
  printf "%s/%s/%s\n" "$DOWNLOADS_DIR" "$(sanitize_filename "$folder")" "$(sanitize_filename "${title} - ${artists}").mp3"
}

choose_artist_top_n() {
  echo
  echo "Choose artist top-tracks size:"
  echo "  1) Top 10"
  echo "  2) Top 25"
  echo "  3) All"
  prompt "Select [1-3]: "
  case "$REPLY" in
    1) echo 10 ;;
    2) echo 25 ;;
    *) echo 1000 ;;
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
    artist)
      local all topn; all="$(fetch_artist_top_tracks "$id" "$token" "$MARKET")"; topn="$(choose_artist_top_n)"; out="$(echo "$all" | jq -c ".[0:$topn]")"
      ;;
    *) die "Unsupported Spotify type: $type" ;;
  esac
  echo "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || die "Spotify returned unexpected data (not a track list). If private, make it public."
  printf "%s" "$out"
}

process_spotify_url() {
  local url="$1" preview="${2:-0}"
  mkdir -p "$DOWNLOADS_DIR"
  local tracks; tracks="$(resolve_tracks "$url")"
  local len; len="$(echo "$tracks" | jq 'length')"
  [ "$len" -gt 0 ] || die "No tracks found."

  print_tracks "$tracks"

  local type; type="$(parse_spotify_type_id "$url" | awk '{print $1}')"
  local folder="Playlist"; case "$type" in album) folder="Album" ;; track) folder="Single" ;; artist) folder="ArtistTop" ;; esac
  [ "$preview" = "1" ] && { echo "$(cc 2)Preview complete — no downloads executed.$(cr)"; return 0; }

  prompt "Proceed to download as MP3 320k? [y/N] "
  case "${REPLY,,}" in y|yes) ;; *) echo "Cancelled."; return 0;; esac

  # Concurrency controller (1..3)
  local -a pids=()
  local active=0 idx=0

  while [ $idx -lt $len ]; do
    local title artists primary dest name q
    title="$(echo "$tracks" | jq -r ".[$idx].title")"
    artists="$(echo "$tracks" | jq -r ".[$idx].artists | join(\", \")")"
    primary="$(echo "$tracks" | jq -r ".[$idx].artists[0]")"
    q="${title} ${primary} audio"
    dest="$(build_dest "$folder" "$title" "$artists")"
    name="$(sanitize_filename "$title")"

    if [ "$SKIP_EXISTING" = "1" ] && [ -f "$dest" ]; then
      ok "skip (exists): $dest"
      idx=$((idx+1))
      continue
    fi

    # Slot control
    if [ $active -ge $CONCURRENCY ]; then
      wait -n || true
      active=$((active-1))
    fi

    # Launch one download in background while showing its own progress
    (
      download_one "$q" "$dest" "$name"
    ) &
    pids+=($!)
    active=$((active+1))
    idx=$((idx+1))
  done

  # Wait remaining
  for pid in "${pids[@]:-}"; do wait "$pid" || true; done
  ok "Saved under: $DOWNLOADS_DIR/$folder"
}

menu() {
  while true; do
    clear || true
    title "BSpot (Spotify-only, MP3)"
    echo "  1) Paste a Spotify link"
    echo "  2) Preview only (no download)"
    echo "  3) Toggle skip existing (now: ${SKIP_EXISTING})"
    echo "  4) Set concurrency (now: ${CONCURRENCY}, 1..3)"
    echo "  5) Quit"
    line
    prompt "Select: "
    case "$REPLY" in
      1) prompt "Paste Spotify URL: "; local url="$REPLY"; is_spotify "$url" || { warn "Not a Spotify link."; sleep 1; continue; }; process_spotify_url "$url" 0; prompt "Press Enter...";;
      2) prompt "Paste Spotify URL: "; local url="$REPLY"; is_spotify "$url" || { warn "Not a Spotify link."; sleep 1; continue; }; process_spotify_url "$url" 1; prompt "Press Enter...";;
      3) if [ "$SKIP_EXISTING" = "1" ]; then SKIP_EXISTING="0"; else SKIP_EXISTING="1"; fi; sed -i "s/^SKIP_EXISTING=.*/SKIP_EXISTING=\"$SKIP_EXISTING\"/" "$CONFIG_FILE"; ok "Skip existing set to $SKIP_EXISTING"; sleep 0.7 ;;
      4) prompt "Enter concurrency [1..3]: "; local c="$REPLY"; [[ "$c" =~ ^[1-3]$ ]] || { warn "Invalid"; sleep 0.7; continue; }; CONCURRENCY="$c"; sed -i "s/^CONCURRENCY=.*/CONCURRENCY=\"$CONCURRENCY\"/" "$CONFIG_FILE"; ok "Concurrency set to $CONCURRENCY"; sleep 0.7 ;;
      5|q|Q) exit 0 ;;
      -h|--help) usage; prompt "Press Enter...";;
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
    local url="$1"
    is_spotify "$url" || die "This program supports only Spotify URLs."
    process_spotify_url "$url" 0
    exit 0
  fi
  menu
}
main "$@"
