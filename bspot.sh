#!/usr/bin/env bash
set -euo pipefail

# BSpotDownloader (Linux, self-updating via launcher)
# - Uses ~/.config/bspot/config for persistent settings
# - Does NOT re-prompt for Spotify creds unless missing
# - Audio-only .mp4 output with highest practical quality (AAC 320k)
# - Menu mode or URL-as-argument mode

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

die(){ echo "Error: $*" >&2; exit 1; }
say(){ echo "[*] $*"; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  for c in curl jq yt-dlp ffmpeg; do
    have_cmd "$c" || die "Missing required command: $c"
  done
}

first_time_config() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "First-time setup for BSpotDownloader"
    read -r -p "Enter Spotify Client ID: " cid
    read -r -p "Enter Spotify Client Secret: " csec
    {
      echo "SPOTIFY_CLIENT_ID=\"$cid\""
      echo "SPOTIFY_CLIENT_SECRET=\"$csec\""
      echo "DOWNLOADS_DIR=\"$HOME/Downloads/BSpotDownloader\""
      echo "OUTPUT_EXTENSION=\"mp4\""
      echo "YTDLP_SEARCH_COUNT=\"1\""
      echo "UPDATE_POLICY=\"auto\""  # for consistency; launcher enforces updates
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  fi
}

load_config() {
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  : "${SPOTIFY_CLIENT_ID:?Missing SPOTIFY_CLIENT_ID in config}"
  : "${SPOTIFY_CLIENT_SECRET:?Missing SPOTIFY_CLIENT_SECRET in config}"
  : "${DOWNLOADS_DIR:?Missing DOWNLOADS_DIR in config}"
  : "${OUTPUT_EXTENSION:=mp4}"
  : "${YTDLP_SEARCH_COUNT:=1}"
}

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

is_spotify() {
  local u="${1,,}"
  [[ "$u" == *"open.spotify.com/"* || "$u" == spotify:* ]]
}

spotify_parse_type_id() {
  local url="$1"
  if [[ "$url" == spotify:* ]]; then
    IFS=':' read -r _ type id <<<"$url"
    echo "$type" "$id"; return
  fi
  local path
  path="$(echo "$url" | sed -E 's#https?://open\.spotify\.com/##' | cut -d'?' -f1)"
  local type id
  type="$(echo "$path" | cut -d'/' -f1)"
  id="$(echo "$path" | cut -d'/' -f2)"
  echo "$type" "$id"
}

spotify_token() {
  local id="$1" sec="$2"
  curl -sS -u "${id}:${sec}" \
    -d grant_type=client_credentials \
    https://accounts.spotify.com/api/token | jq -r '.access_token'
}

spotify_get_tracks_json() {
  local type="$1" id="$2" token="$3"
  case "$type" in
    playlist)
      local url="https://api.spotify.com/v1/playlists/${id}/tracks?limit=100"
      local items="[]"
      while [ -n "$url" ] && [ "$url" != "null" ]; do
        local page
        page="$(curl -sS -H "Authorization: Bearer $token" "$url")"
        local part
        part="$(echo "$page" | jq -c '[.items[]? | select(.track != null and .track.type == "track") | {
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
        local page
        page="$(curl -sS -H "Authorization: Bearer $token" "$url")"
        local items
        items="$(echo "$page" | jq -c '[.items[]? | {
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
      local tjson
      tjson="$(curl -sS -H "Authorization: Bearer $token" "https://api.spotify.com/v1/tracks/${id}")"
      echo "$tjson" | jq -c '[{
        title: .name,
        artists: (.artists | map(.name)),
        album: .album.name,
        duration_ms: .duration_ms
      }]'
      ;;
    *)
      die "Unsupported Spotify type: $type"
      ;;
  esac
}

print_tracks() {
  local tracks_json="$1"
  local count; count="$(echo "$tracks_json" | jq 'length')"
  echo "Found ${count} track(s):"
  echo "$tracks_json" | jq -r '.[] | "- " + .title + " — " + (.artists | join(", "))'
}

build_dest_path() {
  local folder="$1" title="$2" artists="$3" ext="$4"
  local fdir="$(sanitize_filename "$folder")"
  local fname="$(sanitize_filename "${title} - ${artists}").${ext}"
  printf "%s/%s/%s\n" "$DOWNLOADS_DIR" "$fdir" "$fname"
}

ensure_dir(){ mkdir -p "$1"; }

download_audio_mp4_from_search() {
  # Download bestaudio and transcode/remux to .mp4 (AAC 320k)
  local query="$1" dest="$2"
  local parent; parent="$(dirname "$dest")"
  ensure_dir "$parent"
  local tmpl="${parent}/%(title)s.%(ext)s"
  echo "Downloading (search): $query"
  yt-dlp -q -f "bestaudio/best" -o "$tmpl" "ytsearch1:${query}"
  local latest
  latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"
  if [ -z "$latest" ]; then
    echo "Warning: no file downloaded for: $query" >&2
    return 1
  fi
  ffmpeg -y -hide_banner -loglevel error -i "$latest" -vn -c:a aac -b:a 320k "$dest"
  rm -f -- "$latest"
  echo "Saved -> $dest"
}

download_direct_url_mp4() {
  local url="$1" outdir="$2"
  ensure_dir "$outdir"
  echo "Downloading directly to audio-only .mp4..."
  local tmpl="${outdir}/%(title)s.%(ext)s"
  yt-dlp -f "bestaudio/best" -o "$tmpl" "$url"
  shopt -s nullglob
  for src in "$outdir"/*; do
    if [[ "${src,,}" == *.mp4 ]]; then continue; fi
    local base="$(basename "$src")"
    local name="${base%.*}"
    local dest="${outdir}/$(sanitize_filename "$name").mp4"
    ffmpeg -y -hide_banner -loglevel error -i "$src" -vn -c:a aac -b:a 320k "$dest"
    rm -f -- "$src"
    echo "Saved -> $dest"
  done
}

menu() {
  echo "===== BSpotDownloader (Linux) ====="
  echo "1) Paste a link to process"
  echo "2) Show current config (secret redacted)"
  echo "3) Quit"
  echo "==================================="
  read -r -p "Select: " choice
  case "$choice" in
    1)
      read -r -p "Paste Spotify/YouTube/etc. URL: " url
      process_url "$url"
      ;;
    2)
      echo "Config file: $CONFIG_FILE"
      sed 's/^\(SPOTIFY_CLIENT_SECRET=\).*/\1"***REDACTED***"/' "$CONFIG_FILE" || true
      ;;
    3|q|Q)
      exit 0
      ;;
    *)
      echo "Invalid choice"
      ;;
  esac
}

process_url() {
  local url="$1"
  mkdir -p "$DOWNLOADS_DIR"

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
    echo
    read -r -p "Download all as audio-only .mp4? [y/N] " ans
    case "${ans,,}" in y|yes) ;; *) echo "Cancelled."; return 0;; esac

    local folder="Playlist"
    case "$type" in album) folder="Album" ;; track) folder="Single" ;; esac

    for i in $(seq 0 $((len-1))); do
      local title joined primary q dest
      title="$(echo "$tracks" | jq -r ".[$i].title")"
      joined="$(echo "$tracks" | jq -r ".[$i].artists | join(\", \")")"
      primary="$(echo "$tracks" | jq -r ".[$i].artists[0]")"
      q="${title} ${primary} audio"
      dest="$(build_dest_path "$folder" "$title" "$joined" "$OUTPUT_EXTENSION")"
      if [ -f "$dest" ]; then
        echo "Exists, skipping: $dest"
        continue
      fi
      if ! download_audio_mp4_from_search "$q" "$dest"; then
        echo "Failed: $title — $joined" >&2
      fi
    done
    echo "Done. Saved under: $DOWNLOADS_DIR/$folder"

  else
    local folder="Direct"
    if [[ "${url,,}" == *"youtube.com/"* || "${url,,}" == *"youtu.be/"* ]]; then
      folder="YouTube"
    fi
    local outdir="${DOWNLOADS_DIR}/$(sanitize_filename "$folder")"
    download_direct_url_mp4 "$url" "$outdir"
    echo "Done. Saved under: $outdir"
  fi
}

main() {
  require_cmds
  first_time_config
  load_config

  if [ $# -gt 0 ]; then
    process_url "$1"
    exit 0
  fi

  while true; do
    menu
    echo
  done
}

main "$@"
