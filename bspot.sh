#!/usr/bin/env bash
set -euo pipefail

# BSpot (Spotify-only) — MP3 320k with cover art + Stage 3 & 4 UX
# - Neon banner (non-spam: once at menu; subtle glow on track start)
# - Live top progress bar with waveform ribbon
# - Post-processing:
#   * 60s crossfade sampler (default: 6 clips x 10s with 2s crossfades)
#   * 15s epilogue video (1080p) with banner + scrolling track list + gentle audio bed
# Supports: playlist, album, track, artist (top tracks)
# Config: ~/.config/bspot/config (reused)

CONFIG_DIR="${HOME}/.config/bspot"
CONFIG_FILE="${CONFIG_DIR}/config"

# ===================== UI helpers =====================
is_tty() { [ -t 1 ]; }
cc() { is_tty && tput setaf "$1" || true; }
cb() { is_tty && tput bold || true; }
cr() { is_tty && tput sgr0 || true; }
mv_home(){ tput cup 0 0 >/dev/null 2>&1 || true; }
savec(){ tput sc >/dev/null 2>&1 || true; }
restc(){ tput rc >/dev/null 2>&1 || true; }
line() { printf "%s\n" "────────────────────────────────────────────────────────"; }
bar()  { printf "%s\n" "========================================================"; }

BANNER_TXT=$'██████╗░░██████╗██████╗░░█████╗░████████╗\n██╔══██╗██╔════╝██╔══██╗██╔══██╗╚══██╔══╝\n██████╦╝╚█████╗░██████╔╝██║░░██║░░░██║░░░\n██╔══██╗░╚═══██╗██╔═══╝░██║░░██║░░░██║░░░\n██████╦╝██████╔╝██║░░░░░╚█████╔╝░░░██║░░░\n╚═════╝░╚═════╝░╚═╝░░░░░░╚════╝░░░░╚═╝░░░'

banner_once_printed="0"

banner_sweep_once() {
  [ "$banner_once_printed" = "1" ] && return 0
  banner_once_printed="1"
  IFS=$'\n' read -rd '' -a lines <<<"$BANNER_TXT" || true
  local colors=(6 5 3 2 4 1)
  for i in "${colors[@]}"; do
    for row in "${lines[@]}"; do printf "%s%s%s\n" "$(cc "$i")" "$row" "$(cr)"; done
    sleep 0.05
    tput cuu ${#lines[@]} >/dev/null 2>&1 || true
  done
  for row in "${lines[@]}"; do printf "%s%s%s\n" "$(cc 6)" "$row" "$(cr)"; done
}

track_glow() {
  # single-line glow before each track (no big banner)
  local txt="▶ $(sanitize_filename "$1")"
  for c in 6 5 3 2 4; do
    echo "$(cc $c)$txt$(cr)"
    tput cuu1 >/dev/null 2>&1 || true
    sleep 0.04
  done
  echo "$(cc 6)$txt$(cr)"
}

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

# ===================== Config =====================
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

# ===================== Helpers =====================
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

timestamp() { date +%Y%m%d_%H%M%S; }

# ===================== Network =====================
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

# ===================== Normalizers (with track_id) =====================
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
    next="$(echo "$page" | jq -r '.next')"
    url="$next"
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

# ===================== Cover art =====================
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

# ===================== Presentation & Hype =====================
print_tracks() {
  local tracks="$1"
  local n; n="$(echo "$tracks" | jq 'length')"
  echo
  title "Tracks queued: $n"
  echo "$tracks" | jq -r '.[] | "- \(.title) — \((.artists | join(", ")))"'
  bar
}

build_dest() {
  local folder="$1" title="$2" artists="$3"
  printf "%s/%s/%s\n" "$DOWNLOADS_DIR" "$(sanitize_filename "$folder")" "$(sanitize_filename "${title} - ${artists}").mp3"
}

hype_moment() {
  local title="$1" duration_ms="$2"
  local mins=$(( (duration_ms/1000)/60 ))
  local t="${title,,}"
  local msg=""
  if [ "$mins" -ge 6 ]; then msg="Epic length detected — settle in."
  elif [[ "$t" == *"live"* || "$t" == *"unplugged"* ]]; then msg="Live vibes incoming — feel the room."
  elif [[ "$t" == *"remix"* || "$t" == *"edit"* ]]; then msg="Alternate cut — fresh spin."
  elif [[ "$t" == *"symphony"* || "$t" == *"concerto"* || "$t" == *"raga"* ]]; then msg="Serious musicianship on deck."
  fi
  [ -n "$msg" ] && echo "$(cc 5)★ $msg$(cr)"
}

# ===================== Waveform progress =====================
print_progress_top() {
  local name="$1" line="$2" waveseg="$3"
  local pct speed eta
  pct="$(sed -n 's/.*\[\s*download\s*\]\s*\([0-9.]\+%\).*/\1/p' <<< "$line" | tail -n1 || true)"
  speed="$(sed -n 's/.*at\s\([0-9.]\+[KMG]iB\/s\).*/\1/p' <<< "$line" | tail -n1 || true)"
  eta="$(sed -n 's/.*ETA\s\([0-9:]\+\).*/\1/p' <<< "$line" | tail -n1 || true)"

  local p=0; [[ "$pct" =~ ^([0-9]+) ]] && p="${BASH_REMATCH[1]}"
  local w=34 filled=$(( p * w / 100 )) empty=$(( w - filled ))
  local pbar="$(printf "%0.s█" $(seq 1 $filled))$(printf "%0.s░" $(seq 1 $empty))"

  savec; mv_home
  printf "%s\r" "$(cb)$(cc 6)♪ $(sanitize_filename "$name")$(cr)"
  printf "\n[%s] %3s  %s  %s\r" "$pbar" "${pct:-..%}" "${eta:+ETA $eta}" "${speed:-}"
  printf "\n%s\r" "${waveseg:-}"
  restc
}

clear_progress_top() {
  savec; mv_home
  printf "%-100s\r" ""; printf "\n%-100s\r" ""; printf "\n%-100s\r" ""
  restc
}

make_wave_snippet() {
  local infile="$1"
  local vals; vals="$(ffmpeg -hide_banner -loglevel error -t 0.35 -i "$infile" -af astats=metadata=1:reset=1 -f null - 2>&1 \
     | awk -F': ' '/Peak_level/ {printf("%.3f ",$2)}' 2>/dev/null || true)"
  [ -z "$vals" ] && { echo ""; return 0; }
  local out="" v scaled ch idx=0
  for v in $vals; do
    scaled=$(awk -v x="$v" 'BEGIN{ s=(x+60)/60; if(s<0)s=0; if(s>1)s=1; printf("%.2f",s)}')
    ch="░"
    awk -v s="$scaled" 'BEGIN{
      if(s>0.80)print "█";
      else if(s>0.55)print "▓";
      else if(s>0.30)print "▒";
      else print "░";
    }' | read -r ch
    out="$out$ch"; idx=$((idx+1)); [ $idx -ge 60 ] && break
  done
  local pad=$((60 - idx)); [ $pad -gt 0 ] && out="$out$(printf "%0.s░" $(seq 1 $pad))"
  echo "$out"
}

# ===================== Download one =====================
download_one() {
  local query="$1" dest="$2" name="$3" cover_url="$4"
  local parent; parent="$(dirname "$dest")"
  mkdir -p "$parent"
  local tmpl="${parent}/%(title)s.%(ext)s"

  track_glow "$name"

  local q1="$query"
  local q2="${query/, / }"
  local cover_file=""

  if [ -n "${cover_url:-}" ]; then
    cover_file="$(download_cover_to_tmp "$cover_url")"
    [ -n "$cover_file" ] || warn "cover fetch failed for: $name"
  fi

  local latest="" wave=""
  for q in "$q1" "$q2"; do
    if yt-dlp --newline -q --default-search ytsearch -f "bestaudio/best" -o "$tmpl" "ytsearch1:${q}" 2>/dev/null | \
       while IFS= read -r ln; do
         if [[ "$ln" == "[download]"* ]]; then
           if [ -z "$latest" ]; then latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"; fi
           if [ -n "$latest" ] && [ -z "$wave" ]; then wave="$(make_wave_snippet "$latest" || echo "")"; fi
           print_progress_top "$name" "$ln" "$wave"
         fi
       done
    then
      latest="$(ls -t "${parent}"/* 2>/dev/null | head -n1 || true)"
      if [ -n "$latest" ]; then
        clear_progress_top
        if [ -n "$cover_file" ]; then
          ffmpeg -y -hide_banner -loglevel error \
            -i "$latest" -i "$cover_file" \
            -map 0:a:0 -map 1:v:0 \
            -c:a libmp3lame -b:a 320k \
            -id3v2_version 3 \
            -metadata:s:v title="Album cover" \
            -metadata:s:v comment="Cover (front)" \
            -disposition:v attached_pic \
            "$dest"
        else
          ffmpeg -y -hide_banner -loglevel error \
            -i "$latest" -c:a libmp3lame -b:a 320k "$dest"
        fi
        rm -f -- "$latest"; [ -n "$cover_file" ] && rm -f -- "$cover_file"
        ok "$dest"
        return 0
      fi
    fi
  done

  clear_progress_top
  [ -n "$cover_file" ] && rm -f -- "$cover_file"
  warn "no source matched for: $name"
  return 1
}

# ===================== Stage 4: Sampler + Epilogue =====================
# Build 60s sampler: N=6 clips, each 10s, crossfade 2s, starting 30s in.
build_sampler() {
  local -a files=("$@")
  local count="${#files[@]}"; [ "$count" -lt 2 ] && { warn "sampler: need at least 2 tracks"; return 0; }
  local N=6 CLIP=10 START=30 XFADE=2
  [ "$count" -lt "$N" ] && N="$count"
  local tmpdir; tmpdir="$(mktemp -d)"
  local clips=() i=0
  while [ $i -lt $N ]; do
    local src="${files[$i]}"; local clip="$tmpdir/clip_$i.mp3"
    ffmpeg -y -hide_banner -loglevel error -ss $START -t $CLIP -i "$src" -af "loudnorm=I=-14:LRA=11:TP=-1.5" -c:a libmp3lame -b:a 320k "$clip"
    clips+=("$clip"); i=$((i+1))
  done
  local out="$DOWNLOADS_DIR/Sampler_$(timestamp).mp3"
  # Ladder crossfade
  local current="${clips[0]}" k=1
  while [ $k -lt $N ]; do
    local next="${clips[$k]}" comb="$tmpdir/xf_$k.mp3"
    ffmpeg -y -hide_banner -loglevel error -i "$current" -i "$next" \
      -filter_complex "acrossfade=d=$XFADE:curve1=tri:curve2=tri" \
      -c:a libmp3lame -b:a 320k "$comb"
    current="$comb"; k=$((k+1))
  done
  mv "$current" "$out"
  rm -rf "$tmpdir"
  ok "Sampler created: $out"
}

# Build 15s epilogue video with banner + scrolling track list + audio bed.
build_epilogue() {
  local -a files=("$@"); local count="${#files[@]}"
  [ "$count" -lt 1 ] && { warn "epilogue: need at least 1 track"; return 0; }

  local out="$DOWNLOADS_DIR/Epilogue_$(timestamp).mp4"
  local list_txt="$(mktemp)"; local i=0
  echo "Downloaded tracks:" > "$list_txt"
  for f in "${files[@]}"; do
    echo "• $(basename "$f")" >> "$list_txt"
  done

  # Pick last file for ambient bed; take last 15s with fade
  local bed="${files[$((count-1))]}"
  local bed_aac="$(mktemp --suffix=.m4a)"
  ffmpeg -y -hide_banner -loglevel error -sseof -15 -i "$bed" -af "afade=in:st=0:d=2,afade=out:st=13:d=2,volume=0.7" -c:a aac -b:a 192k "$bed_aac"

  # Build a 1080p 15s canvas with banner and scrolling text
  # Find a monospace font
  local FONT="$(fc-match -f '%{file}\n' monospace 2>/dev/null | head -n1 || echo '')"
  local drawfont=""
  [ -n "$FONT" ] && drawfont=":fontfile='$FONT'"

  # Escape banner for drawtext
  local banner_esc="$(echo "$BANNER_TXT" | sed "s/'/\\\'/g" | sed ':a;N;$!ba;s/\n/\\\\n/g')"

  ffmpeg -y -hide_banner -loglevel error -f lavfi -t 15 -i "color=c=black:s=1920x1080:r=30" \
    -i "$bed_aac" \
    -vf "drawtext=fontsize=38:text='$banner_esc'$drawfont:x=(w-text_w)/2:y=50:fontcolor=white:shadowx=2:shadowy=2,\
         drawtext=fontsize=28:textfile='$list_txt'$drawfont:x=60:y=h-(t*120):fontcolor=white:shadowx=2:shadowy=2" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k "$out"

  rm -f "$list_txt" "$bed_aac"
  ok "Epilogue video: $out"
}

# ===================== Resolve + run =====================
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

  local type; type="$(parse_spotify_type_id "$url" | awk '{print $1}')"
  local folder="Playlist"; case "$type" in album) folder="Album" ;; track) folder="Single" ;; artist) folder="ArtistTop" ;; esac

  printf "%s" "Proceed to download as MP3 320k? [y/N] "
  read -r ans; case "${ans,,}" in y|yes) ;; *) echo "Cancelled."; return 0;; esac

  local token; token="$(spotify_get_token "$SPOTIFY_CLIENT_ID" "$SPOTIFY_CLIENT_SECRET")"
  local -a saved=()

  for i in $(seq 0 $((len-1))); do
    local title artists primary dest name q track_id cover_url dur
    title="$(echo "$tracks" | jq -r ".[$i].title")"
    artists="$(echo "$tracks" | jq -r ".[$i].artists | join(\", \")")"
    primary="$(echo "$tracks" | jq -r ".[$i].artists[0]")"
    track_id="$(echo "$tracks" | jq -r ".[$i].track_id // empty")"
    dur="$(echo "$tracks" | jq -r ".[$i].duration_ms // 0")"

    q="${title} ${primary} audio"
    dest="$(build_dest "$folder" "$title" "$artists")"
    name="$(sanitize_filename "$title")"

    if [ "$SKIP_EXISTING" = "1" ] && [ -f "$dest" ]; then
      ok "skip (exists): $dest"; saved+=("$dest"); continue
    fi

    hype_moment "$title" "$dur"

    cover_url=""; [ -n "$track_id" ] && cover_url="$(get_cover_by_track_id "$track_id" "$token" || echo "")"

    if download_one "$q" "$dest" "$name" "$cover_url"; then
      saved+=("$dest")
    fi
  done

  ok "Saved under: $DOWNLOADS_DIR/$folder"

  # Stage 4 prompts
  if [ "${#saved[@]}" -ge 2 ]; then
    printf "%s" "Create 60s crossfade sampler? [y/N] "
    read -r mk; [[ "${mk,,}" =~ ^y ]] && build_sampler "${saved[@]}"
  fi
  if [ "${#saved[@]}" -ge 1 ]; then
    printf "%s" "Create 15s epilogue video? [y/N] "
    read -r mv; [[ "${mv,,}" =~ ^y ]] && build_epilogue "${saved[@]}"
  fi
}

menu() {
  while true; do
    clear || true
    banner_sweep_once
    title "BSpot (Spotify-only, MP3 with cover art + Waveform + Sampler/Epilogue)"
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
