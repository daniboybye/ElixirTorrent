# Changelog

## 0.1.2 - 2026-06-09

- `ElixirTorrent.list_files/1` — file list with per-file download progress
- `ElixirTorrent.remove/2` — stop a torrent; optional `delete_data: true` removes files from disk
- Requires Elixir `~> 1.20`

## 0.1.1 - 2026-02-22

- Published HexDocs for the public API (`ElixirTorrent`, `Torrents`)
- `ElixirTorrent.stats/2` documented as the preferred way to read runtime stats

## 0.1.0 - 2026-02-22

First public release — BitTorrent client **engine** publishable as a Hex dependency.

**Public API**

- `ElixirTorrent.download/1` — start a download from a `.torrent` file on disk
- `ElixirTorrent.stats/2` — poll name, speeds, and progress for a running torrent
- Escript entrypoint for CLI usage

**Protocol & networking**

- Peer wire protocol (BEP 3) with choking, rarest-first piece selection, and endgame mode
- Fast Extension (BEP 6) — `allowed_fast`, reject on choked requests
- IPv6 tracker peers (`peers6`) and dual-stack listen sockets
- Multi-homed HTTP announce (BEP 7) over IPv4 and IPv6
- HTTP and UDP trackers (BEP 15), compact peer lists (BEP 23)

**Reliability**

- Improved choke recovery, piece availability tracking, and tracker announce handling
