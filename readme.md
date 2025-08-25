```markdown
# BSpot — Spotify-only MP3 Downloader (Linux)

Minimal, fast, and reliable. Paste a Spotify link, get properly tagged MP3s at the chosen quality with embedded cover art. Calm terminal UI. Clean library structure.

- Output: MP3 CBR (320/192/128/96 kbps) with cover art  
- Sources: Spotify playlist, album, track, or artist (top tracks)  
- Organization:
  - BSpot/Single/{PrimaryArtist}/Title.mp3
  - BSpot/Playlist/{PrimaryArtist}/Title.mp3

---

## Highlights

- Spotify-only focus for a “just works” flow  
- Proper ID3 tags + embedded album art  
- Quiet progress line with ETA/speed  
- Artist-first folders; filenames are only the song title  
- Quality selector with per‑track size estimates  

---

## Requirements

- Linux, Bash  
- curl, jq, ffmpeg, yt-dlp (checked during install; installer attempts to fetch if missing)

---

## Installation

```
curl -fsSL https://raw.githubusercontent.com/your-user/your-repo/master/install_bspot.sh | bash
```

This will:
- Install `bspot` to `/usr/local/bin`
- Put the app script under `~/.local/share/bspot/`
- Create `~/.config/bspot/config` on first run

Uninstall any time:

```
bspot --uninstall
```

---

## First Run

```
bspot
```

Enter once (saved to config):
- Spotify Client ID  
- Spotify Client Secret  
- Download folder (default: `~/Downloads/BSpot`)

---

## Usage (All-in-One)

Menu mode (recommended):

```
bspot
# 1 → paste any Spotify link (playlist/album/track/artist)
# choose quality (320/192/128/96) → confirm
```

Direct mode (no menu):

```
bspot "https://open.spotify.com/playlist/<playlist_id>"
bspot "https://open.spotify.com/album/<album_id>"
bspot "https://open.spotify.com/track/<track_id>"
bspot "https://open.spotify.com/artist/<artist_id>"   # then choose Top 10/25/All
```

What happens next (one flow):
1. BSpot resolves all tracks for the link.  
2. Prompts for MP3 quality (or uses saved default).  
3. Shows per‑track size estimate.  
4. Downloads audio, embeds cover art, writes tags, and saves to:
   - `~/Downloads/BSpot/Single/{PrimaryArtist}/Title.mp3` for a single track link
   - `~/Downloads/BSpot/Playlist/{PrimaryArtist}/Title.mp3` for playlist/album/artist links

---

## Quality & Size Estimates (Built-in)

- Very high: 320 kbps  
- High: 192 kbps  
- Medium: 128 kbps  
- Low: 96 kbps  

Size estimate per track is shown before download (based on duration × bitrate).  
Quick storage guide:
- 320 kbps ≈ ~2.4 MB/min  
- 192 kbps ≈ ~1.44 MB/min  
- 128 kbps ≈ ~0.96 MB/min  
- 96 kbps  ≈ ~0.72 MB/min  

Example: 3:30 at 320 kbps ≈ ~8.4–9.0 MB.

---

## Output Structure

Base directory: `~/Downloads/BSpot`

```
BSpot/
├── Single/
│   └── {PrimaryArtist}/
│       └── Title.mp3
└── Playlist/
    └── {PrimaryArtist}/
        └── Title.mp3
```

- Primary artist = first artist on Spotify.  
- Filenames are only `Title.mp3`.  
- Artist folders are created on demand.

---

## Tags & Cover Art

Each MP3 includes:
- title → track title  
- artist → all artists joined by “; ”  
- album_artist → primary artist  
- album → album name (if available)  
- embedded cover art → largest album image (attached picture)  

This keeps names simple while players still display all collaborators.

---

## Configuration

File: `~/.config/bspot/config`

```
SPOTIFY_CLIENT_ID="..."
SPOTIFY_CLIENT_SECRET="..."
DOWNLOADS_DIR="/home/you/Downloads/BSpot"
YTDLP_SEARCH_COUNT="1"
MARKET="US"
SKIP_EXISTING="1"
QUALITY_PRESET="320"   # "", 320, 192, 128, 96
```

Tips:
- Set `QUALITY_PRESET` to skip the quality prompt next runs.
- Change `MARKET` to affect artist top‑tracks country.
- Keep `SKIP_EXISTING=1` to avoid re-downloading.

---

## Everything at a Glance (One Section)

- Install:
  ```
  curl -fsSL https://raw.githubusercontent.com/your-user/your-repo/master/install_bspot.sh | bash
  ```
- Run:
  ```
  bspot
  ```
- Paste:
  - Playlist / Album / Track / Artist link
- Choose quality:
  - 320 / 192 / 128 / 96 kbps (shows size estimate)
- Files appear in:
  - `BSpot/Single/{PrimaryArtist}/Title.mp3` (track)
  - `BSpot/Playlist/{PrimaryArtist}/Title.mp3` (playlist/album/artist)
- Tags + cover art embedded automatically
- Config:
  - `~/.config/bspot/config` (edit `QUALITY_PRESET` to remember quality)

---

## Lightweight Stats (Rule-of-thumb)

- Per‑track time @320 kbps on typical broadband: ~5–12 s  
- 50‑track playlist (avg 3:30) @320 kbps: ~420–450 MB total  
- 1,000 tracks @3:30 @320 kbps: ~8.5–9.0 GB

---

## Troubleshooting

- API 404 or “No tracks found” → Link may be private or malformed. Ensure it’s public and clean (no extra query/hash).  
- Artist top‑tracks empty/odd → Change `MARKET` in config.  
- Wrong match → Re-run; try a different market or quality. Duration estimate helps sanity-check results.  
- Stalls → Check connectivity; re-run. Existing files are skipped.

---

## Roadmap

- Optional strict duration matching (reject > ±5% mismatches)  
- Optional secondary-artist symlinks (file visible in multiple artist folders)  
- Optional CSV/JSON export of downloaded queue

---

## Contributing

- Keep it portable (Bash + curl + jq + ffmpeg + yt-dlp).  
- Test on a clean Linux shell.  
- PRs welcome.

---

## License

MIT (or your preferred license). Add a LICENSE file to the repo.

---

## Credits

- Bash, curl, jq, ffmpeg, yt-dlp  
- Spotify metadata via public Web API
```

[1](https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/attachments/images/84088221/c422a650-05aa-4ec6-bc25-100066b8cb7f/image.jpg?AWSAccessKeyId=ASIA2F3EMEYEZPX4VUX7&Signature=mlHZAw1NWs2ZRTa2Yfj4xp4F3Lc%3D&x-amz-security-token=IQoJb3JpZ2luX2VjEP7%2F%2F%2F%2F%2F%2F%2F%2F%2F%2FwEaCXVzLWVhc3QtMSJIMEYCIQD8O264WGBBzOJHyDom4QQHGzr0ODlL3kcSS1ka%2BjNOdgIhAOQN9N0q9YFvBuX604pPhOMjoOeGL3HFcU%2Bugaj6MTa9KvEECFcQARoMNjk5NzUzMzA5NzA1Igx%2BGgkzzP%2ByC1sAvA4qzgSCaLHjmx0n4lg3bomj%2B%2FE8jXE%2FaUHJ0Dqn7z8oOlK0qt3rCeMNYOKa3V%2FqcUru6GiGLivYdxwOpyZhlaqhr6BAqyi40Vbgfncdw5SgMOyroPmuoVdTBCSEGN1iNg%2BQqw60nu5w9TmOGPJ0i5LWrmjqwA07L%2BbKDhdbqjCDhskMCtc8yDuTAUU%2F4%2FyB5c2NEsUWVoTX3OBwO42RZeQdrYDepjQkXYk91TWLNt0rBiFpxKW3Q69nc7QPVbrgyTydNW7QieuIhm1o2NzC97CQhSVn8fQFD4bm2QYLZeUzT1cHwuJmxR0Gqmpxdeeq6RFTzBIRgFXyjMppRKjUgwNCN%2BfFZfDgdnpd7OkqltF2IDuaWZ0Xg4TLNzl6%2FiDbzz%2FaPuqvpCRY0IRh7JHJ%2FNOaqf7HaaPCOsTlfxcOyLnQ7GwS%2BBqaxgqpMiE0d1TiBEUl6j0ThkBv2u1PrBvHUA9I%2BM9w8cJS4D8AtbzAparctG4JsEVuzf25gxGjw4UUqljKXlSKh6jRn2KoQ8mlL8hSTnCf0GuFhllVITKWZWT7AfUvL9p1F7EVMKuGXufBxWGOvQ1OknNEboE02MC236ntL8EQGdvdDd%2FSzbLBpq0IkV7Irx%2BA4qKN6TgAbsRWZBUX3Uq6dUCez4s%2F1TQZW8v9mNI5aAy8Luzet04dlhfhj%2FZ1Ooid%2FnxUWbusmsbSWuY9Njl7Tj%2FnFp82vlxnLXr%2FAMEynsoITRr%2BCLefBFq7jpn%2B6Eb2raEzBKFrgxY72OSScGYablkCRSfwEPBPu34UQDCu8q%2FFBjqZARoQfyRJxVpcp6J%2BXF6mfmHcG4m3TRFkbglb2THuIGNdizRoWUoeNFQjXsH5koq4Xhx8i4CtCWlzTxpS3JZPYPLGse3nfN70pUIoS1%2F%2BWosjy7QyQiqtBcyNvZcU5ynhQ9KO%2FgDBTExyuYi8%2BsU2T9Qjnuu%2FqGLoiwMmsd3V9u%2F8AOw55jTxg7fhwcStx2Bw2SZ9mypEhvbYHA%3D%3D&Expires=1756102853)