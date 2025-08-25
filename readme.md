# BSpot · Spotify‑only MP3 Downloader

Paste a Spotify link. Get clean, tagged MP3s with cover art. Calm terminal flow. Beautifully organized files.

- Output: MP3 CBR 320/192/128/96 kbps with embedded cover art
- Inputs: playlist · album · track · artist (top tracks)
- Layout: BSpot/Single|Playlist/{PrimaryArtist}/Title.mp3

------------------------------------------------------------

## ✨ Why BSpot

- Spotify‑only focus so it just works
- Proper ID3 tags + album cover
- Quiet, single‑line progress (percent · ETA · speed)
- Artist‑first folders; filenames are only Title.mp3
- Quality chooser with per‑track size estimates

------------------------------------------------------------

## ⚙️ Requirements

Linux · Bash · curl · jq · ffmpeg · yt‑dlp  
(Installer checks and installs what it can.)

------------------------------------------------------------

## 🚀 Install

```bash
curl -fsSL https://raw.githubusercontent.com/your-user/your-repo/master/install_bspot.sh | bash
```

What happens:
- Installs a launcher: bspot
- Places app under ~/.local/share/bspot
- Creates ~/.config/bspot/config on first run

Uninstall anytime:
```bash
bspot --uninstall
```

------------------------------------------------------------

## ▶️ Use

Menu (recommended)
```bash
bspot
# 1 → paste a Spotify link → pick quality → confirm
```

Direct (no menu)
```bash
bspot "https://open.spotify.com/playlist/<id>"
bspot "https://open.spotify.com/album/<id>"
bspot "https://open.spotify.com/track/<id>"
bspot "https://open.spotify.com/artist/<id>"   # then choose Top 10/25/All
```

What happens:
1) Tracks resolve from Spotify  
2) Choose MP3 quality (or use saved default)  
3) See per‑track size estimate  
4) Download, tag, embed cover, save to tidy folders

------------------------------------------------------------

## 🗂 Output Structure

Base: ~/Downloads/BSpot

```
BSpot/
├─ Single/
│  └─ {PrimaryArtist}/
│     └─ Title.mp3
└─ Playlist/
   └─ {PrimaryArtist}/
      └─ Title.mp3
```

- Primary artist = first listed on Spotify
- Filenames are only Title.mp3
- Artist folders are created on demand

------------------------------------------------------------

## 🏷 Tags & Cover

- title → track title
- artist → all artists joined by “; ”
- album_artist → primary artist
- album → album name (if available)
- cover → largest album image (attached picture)

Players show everyone properly; filenames stay clean.

------------------------------------------------------------

## 🎚 Quality & Size

Pick once per run (or save as default):

- 320 kbps (very high)
- 192 kbps (high)
- 128 kbps (medium)
- 96 kbps (low)

Rule‑of‑thumb storage:
- 320 ≈ 2.4 MB/min
- 192 ≈ 1.44 MB/min
- 128 ≈ 0.96 MB/min
- 96 ≈ 0.72 MB/min

Example: 3:30 @320 ≈ ~8.5–9.0 MB

------------------------------------------------------------

## ⚙️ Config

File: ~/.config/bspot/config

```ini
SPOTIFY_CLIENT_ID="..."
SPOTIFY_CLIENT_SECRET="..."
DOWNLOADS_DIR="/home/you/Downloads/BSpot"
YTDLP_SEARCH_COUNT="1"
MARKET="US"
SKIP_EXISTING="1"
QUALITY_PRESET="320"   # "", 320, 192, 128, 96
```

Tips:
- Set QUALITY_PRESET to skip the quality prompt
- Change MARKET to influence artist top‑tracks
- Keep SKIP_EXISTING=1 to fly through reruns

------------------------------------------------------------

## 🧪 Copy‑paste Examples

Playlist (menu)
```bash
bspot
# 1 → paste playlist URL → 320 kbps → confirm
```

Track (direct)
```bash
bspot "https://open.spotify.com/track/<id>"
```

Artist top tracks
```bash
bspot "https://open.spotify.com/artist/<id>"
# choose Top 10/25/All
```

------------------------------------------------------------

## 📊 Quick Stats

- Typical per‑track time @320: ~5–12 s on home broadband
- 50 tracks @3:30 @320: ~420–450 MB
- 1,000 tracks @3:30 @320: ~8.5–9.0 GB

------------------------------------------------------------

## 🛠 Troubleshooting

- API 404 / “No tracks found” → Link may be private or malformed; ensure it’s public and clean  
- Artist top‑tracks odd/empty → Adjust MARKET in config  
- Mismatch worry → Re‑run; try different MARKET/quality; use size/duration sanity checks  
- Stalls → Check network; rerun (existing files are skipped)

------------------------------------------------------------

## 🗺 Roadmap

- Strict duration matching (reject > ±5% mismatches)
- Optional symlinks for secondary artists
- Optional CSV/JSON export of the queue

------------------------------------------------------------

## 🤝 Contributing

- Keep it portable: Bash + curl + jq + ffmpeg + yt‑dlp  
- Test on a clean Linux shell  
- Small, focused PRs welcome

------------------------------------------------------------

## ⚖️ License

MIT (or your preferred license). Add a LICENSE file.
