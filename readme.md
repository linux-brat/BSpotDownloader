# BSpot — Spotify-only MP3 Downloader (Linux)

Minimal, fast, and reliable. Paste a Spotify link, get properly tagged MP3s at the chosen quality with embedded cover art. Calm terminal UI. Clean library structure.

- Output: MP3 CBR (320/192/128/96 kbps) with cover art
- Sources: Spotify playlist, album, track, or artist (top tracks)
- Organization:
  - BSpot/Single/{PrimaryArtist}/Title.mp3
  - BSpot/Playlist/{PrimaryArtist}/Title.mp3

Badges

- OS: Linux
- Shell: Bash
- Requires: curl, jq, yt-dlp, ffmpeg
- Privacy: local-only, no accounts used

Why BSpot

- Spotify-only focus: Just works with the links used every day
- Clean MP3s: Embedded album cover + proper tags (title, artist list, album artist, album)
- Calm UX: Single-line progress with percent/ETA/speed; sensible prompts
- Tidy folders: Artist-based structure under Single/ and Playlist/
- Quality choice: Pick 320/192/128/96 kbps with per-track size estimates

Quick Start

1) Install

bash
curl -fsSL https://raw.githubusercontent.com/your-user/your-repo/master/install_bspot.sh | bash

This will:
- Check/install dependencies (curl, jq, ffmpeg, yt-dlp)
- Install the launcher bspot to /usr/local/bin
- Create config at ~/.config/bspot/config on first run

2) First run and config

bash
bspot

Enter Spotify Client ID and Secret, then choose a download folder (default: ~/Downloads/BSpot). These are remembered and never asked again unless the config is deleted.

3) Use

- Menu mode
  - Run bspot, press 1, paste a Spotify link

- Direct mode
  - bspot "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"
  - bspot "https://open.spotify.com/track/xxxxxxxxxxxxxxx"
  - bspot "https://open.spotify.com/album/xxxxxxxxxxxxxxx"
  - bspot "https://open.spotify.com/artist/xxxxxxxxxxxxxxx"

Features

- Input types
  - Playlist: Resolves all public tracks (with paging)
  - Album: Resolves all tracks
  - Track: Resolves just one
  - Artist: Offers Top 10/25/All

- Quality selector with size estimates
  - 320 / 192 / 128 / 96 kbps
  - Estimate shows “~X.Y MB” based on duration and bitrate
  - Option to remember the choice in config

- Tags and cover art
  - title → track title
  - artist → all artists joined with “; ”
  - album_artist → primary (first) artist
  - album → album name (if available)
  - embedded cover art → largest album image

- File organization
  - ~/Downloads/BSpot/Single/{PrimaryArtist}/Title.mp3
  - ~/Downloads/BSpot/Playlist/{PrimaryArtist}/Title.mp3
  - Creates artist folders on demand; filenames are just the song title

Basic Workflow

- Paste a Spotify link
- Choose quality (or use saved default)
- See queued tracks
- Confirm; watch a single progress line per track
- Find MP3s in Single/ or Playlist/ under the primary artist folder

Configuration

File: ~/.config/bspot/config

ini
SPOTIFY_CLIENT_ID="..."
SPOTIFY_CLIENT_SECRET="..."
DOWNLOADS_DIR="/home/you/Downloads/BSpot"
YTDLP_SEARCH_COUNT="1"
MARKET="US"
SKIP_EXISTING="1"
QUALITY_PRESET="320"   # or "", 192, 128, 96

Notes:
- QUALITY_PRESET when set (320/192/128/96) skips the quality prompt.
- MARKET is used for artist top-tracks. Change if preferred.
- SKIP_EXISTING=1 keeps re-runs fast by skipping already-saved files.

Installation Details

- Dependencies: curl, jq, ffmpeg, yt-dlp
- If a dependency is missing, the installer attempts to install it via the system package manager; otherwise, it will abort with a clear message.
- The launcher stores the main script under ~/.local/share/bspot and updates it when called, keeping you current.

Uninstall

bash
bspot --uninstall

This removes:
- /usr/local/bin/bspot
- ~/.local/share/bspot
Config remains unless removal is confirmed.

Usage Examples

- Playlist (menu)
  - bspot → 1 → paste playlist URL → choose 320 kbps → confirm

- Track (direct)
  - bspot "https://open.spotify.com/track/xxxxxxxxxxxxxx"

- Artist top tracks
  - bspot "https://open.spotify.com/artist/xxxxxxxxxxxxxx"
  - Pick Top 10/25/All → select quality → confirm

File Size Estimates

- Shown per track before download:
  - Size ≈ bitrate_kbps × duration_seconds ÷ 8 (in bytes), displayed as MB with one decimal
  - Actual sizes are very close (container overhead adds a small difference)

Library Structure Examples

- Single/Arijit Singh/Naam Chale.mp3
- Playlist/Vikram Sarkar/Awadh Mein Ram Aaye Hai.mp3
- Playlist/Prakash Gandhi/Zara Der Thahro Ram.mp3

Known Limits

- Public data only: Uses the standard client-credentials flow. Private playlists are not accessible.
- Matching source: The script finds audio via search; rare titles may need a re-run or slight title/market adjustments.

Troubleshooting

- “Spotify API error (404)”:
  - The link may be private or invalid. Ensure it’s public and the ID is correct (no extra characters/query junk).
- “No tracks found”:
  - Artist top-tracks can vary by market. Try setting MARKET to a relevant country code.
- Progress stalls:
  - Check network connectivity. Re-run; SKIP_EXISTING will speed it up.
- Wrong matches:
  - Try a different quality (it re-queries) or adjust MARKET; duration-based matching is usually close.

Lightweight Stats (template)

- Typical per-track time (320 kbps): ~5–12 s on common home broadband
- Storage guide:
  - 320 kbps: ~2.4 MB/min
  - 192 kbps: ~1.44 MB/min
  - 128 kbps: ~0.96 MB/min
  - 96 kbps: ~0.72 MB/min
- Playlist of 50 tracks (avg 3:30 each):
  - 320 kbps ≈ ~420–450 MB total

Roadmap (optional)

- Optional duration strict matching (reject mismatched sources over ±5%)
- Optional per-artist symlinks for secondary artists
- Optional CSV/JSON export of the queue with tags

Contributing

- PRs are welcome. Keep changes focused and portable.
- Please test on a clean Linux shell (Bash) and avoid external dependencies beyond curl, jq, ffmpeg, yt-dlp.

License

- MIT (or your preferred license). Include a LICENSE file in the repo.

Credits

- Built with Bash + curl + jq + ffmpeg + yt-dlp
- Spotify link parsing and metadata via the public Web API