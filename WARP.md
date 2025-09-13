# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

BSpotDownloader is a Bash-based Spotify music downloader that converts Spotify playlists, albums, tracks, and artist top-tracks into clean MP3 files with embedded cover art and proper ID3 tags. It focuses exclusively on Spotify sources and provides a calm terminal UI with quality selection and organized file output.

## Architecture

### Core Components

- **Main Script (`bspot.sh`)**: The primary application containing all functionality
- **Installer (`install_bspot.sh`)**: Linux installation script that creates a launcher system
- **Configuration**: User settings stored in `~/.config/bspot/config`

### Key Architecture Patterns

**Modular Function Organization**: The script is organized into logical sections:
- UI helpers (colors, progress, banners)
- Configuration management (first-time setup, loading)
- Network operations (Spotify API, token management, retry logic)
- Data fetching (playlist, album, track, artist top-tracks)
- Audio processing (yt-dlp integration, ffmpeg conversion)
- File organization (sanitization, path building)

**Error Handling Strategy**: Uses `set -euo pipefail` with explicit error checking, retry mechanisms, and graceful degradation (e.g., downloads without cover art if cover fetch fails).

**Spotify API Integration**: Token-based authentication with automatic refresh, supports all major Spotify entity types (playlists, albums, tracks, artists), handles pagination for large collections.

**Audio Pipeline**: 
1. Spotify metadata extraction → 
2. YouTube search via yt-dlp → 
3. ffmpeg conversion with quality selection → 
4. ID3 tag embedding → 
5. Cover art attachment → 
6. Organized file placement

## Common Commands

### Development & Testing
```bash
# Test the main script directly (for development)
bash bspot.sh --help

# Test with a single track (fastest feedback)
bash bspot.sh "https://open.spotify.com/track/TRACK_ID"

# Test installer locally
bash install_bspot.sh

# Check script syntax
bash -n bspot.sh
```

### Running the Application
```bash
# Interactive menu (recommended)
bspot

# Direct URL processing
bspot "https://open.spotify.com/playlist/PLAYLIST_ID"
bspot "https://open.spotify.com/album/ALBUM_ID" 
bspot "https://open.spotify.com/track/TRACK_ID"
bspot "https://open.spotify.com/artist/ARTIST_ID"
```

### Debugging & Configuration
```bash
# View current configuration
cat ~/.config/bspot/config

# Test dependencies
curl --version && jq --version && yt-dlp --version && ffmpeg -version

# Clean reinstall (preserves config)
bspot --uninstall
curl -fsSL https://raw.githubusercontent.com/linux-brat/BSpotDownloader/master/install_bspot.sh | bash
```

## Development Guidelines

### Code Style
- **Bash Best Practices**: Use `set -euo pipefail`, quote variables, prefer `[[ ]]` over `[ ]`
- **Function Naming**: Use snake_case with descriptive names (`fetch_playlist_tracks`, `sanitize_filename`)
- **Error Messages**: Consistent format with colored output using helper functions (`die`, `warn`, `ok`)
- **Configuration**: All user settings in single config file, with sensible defaults

### Key Functions to Understand
- `resolve_tracks()`: Main dispatcher that handles different Spotify URL types
- `download_one()`: Core download logic with yt-dlp + ffmpeg pipeline  
- `curl_json()`: Network wrapper with error handling and retry logic
- `sanitize_filename()`: Critical for cross-platform filename compatibility
- `build_dest()`: Implements the organizational file structure

### Testing Considerations
- **API Rate Limits**: Spotify API has rate limits; use small playlists for testing
- **Network Dependencies**: All functionality requires internet; mock for unit testing would need significant refactoring
- **File System**: Test path sanitization with various Unicode/special characters
- **Quality Settings**: Test all bitrate options (320, 192, 128, 96 kbps)

### Common Modification Points
- **Output Structure**: Modify `build_dest()` function
- **Metadata Tags**: Adjust ffmpeg parameters in `download_one()`
- **Search Strategy**: Modify query building in download pipeline
- **UI Elements**: Update banner, colors, or progress display functions
- **API Endpoints**: Extend fetch functions for new Spotify features

## Configuration Details

The application uses a single configuration file at `~/.config/bspot/config`:

```ini
SPOTIFY_CLIENT_ID="your_client_id"
SPOTIFY_CLIENT_SECRET="your_client_secret" 
DOWNLOADS_DIR="/path/to/Downloads/BSpot"
QUALITY_PRESET="320"  # Empty string for prompt, or 320/192/128/96
MARKET="US"           # Affects artist top-tracks
SKIP_EXISTING="1"     # Skip files that already exist
```

### Required Spotify Credentials
Users must obtain Spotify API credentials from the Spotify Developer Dashboard. The app uses Client Credentials flow (no user login required).

## File Organization

Output follows a predictable structure under `DOWNLOADS_DIR`:
```
BSpot/
├── Single/{PrimaryArtist}/Title.mp3      # Individual tracks
└── Playlist/{PrimaryArtist}/Title.mp3    # Playlists, albums, artist collections
```

**Primary Artist**: Always the first artist listed in Spotify metadata  
**Title**: Track title only, no artist names in filename  
**Sanitization**: Removes/replaces filesystem-unsafe characters

## Dependencies

**Required External Tools**:
- `curl`: HTTP requests to Spotify API
- `jq`: JSON parsing and manipulation
- `yt-dlp`: YouTube search and audio download
- `ffmpeg`: Audio conversion, quality control, metadata embedding

The installer attempts automatic installation on major Linux distributions (apt, dnf, pacman, zypper).