# Changelog

## 0.5.0 - 2026-07-22

### Added

- **BEP 9/10 (magnet + ut_metadata):** magnet URI parsing, `download_magnet/1`, LTEP extension protocol, metadata fetch/serve, magnet bootstrap and fetcher supervisors
- **BEP 11 (ut_pex):** peer exchange encode/decode, ingest, and broadcast over LTEP
- **BEP 32 (IPv6 DHT):** separate IPv4/IPv6 routing tables, compact node/peer codecs, dual-stack KRPC and lookup
- **BEP 42:** secure DHT node ID generation from the local IPv4 address
- **BEP 55 (ut_holepunch):** rendezvous/connect/forward hole-punch messages over LTEP; `Peer.Holepunch.Store` for punch state
- **DHT (BEP 5):** routing-table persistence across restarts, dual-stack socket wiring, runtime node-id path fix
- **NAT traversal:** NAT-PMP and UPnP IGD port-mapping clients, STUN mapping-behaviour detection, `NAT.PortMapper` orchestrator
- **MSE/PE:** Message Stream Encryption handshake and RC4 transport layer over `Peer.Transport`
- **uTP (BEP 29):** zombie-connection hardening and BEP 29 off-spec bug fixes
- **Peer discovery/dial:** `Peer.Endpoints`, sticky dial backoff with churn and hard-fail escalation, `Peer.DialStats` per address-family outcomes
- **Acceptor:** global IPv4/IPv6 address helpers, `IpCache` periodic `getifaddrs` snapshot via `:persistent_term`, dual-stack listen logging; LTEP handshakes advertise listen port and global addresses
- README: BEP 9, 10, 11, 32, 42, and 55 rows in Supported BEPs table; `download_magnet/1` in public API table

### Changed

- **Peer I/O:** MSE/PE encryption integrated into the peer transport and sender receive path
- **Peer dial:** immediate-drop churn backoff, endpoint PID lookup via `Peer.Endpoints.get_pid/3`

### Fixed

- DHT node ID persistence file path resolved at runtime instead of compile time

### Notes

- **Started at runtime** (via `ElixirTorrentApplication`): TCP acceptor (with `IpCache`), `PeerDiscovery`, magnet fetcher/bootstrap, and `Peer.Holepunch.Store`
- **Implemented and compiled, not started in supervision:** mainline DHT server, uTP dispatcher, `NAT.PortMapper`, `Peer.Endpoints`, `Peer.DialBackoff`, and `Peer.DialStats` — wiring deferred to a future release
- Default peer acquisition remains **TCP + tracker** (plus magnet metadata bootstrap); DHT announce, uTP fallback dials, NAT mapping, and full hole-punch initiation require the dormant services above


## 0.4.0 - 2026-07-08

### Added

- **BEP 29 (uTP):** `Peer.Transport` over TCP and uTP; uTP packet stack with LEDBAT; connection lifecycle and dispatcher; dial backoff and endpoint registry; outbound TCP-first dial with uTP fallback; inbound uTP handshake entry
- **BEP 5 (DHT):** Mainline DHT KRPC node (ping, find_node, get_peers, announce_peer); k-bucket routing table with bootstrap routers; iterative lookup and announce token workflow; DHT and uTP share one UDP socket via `DHT.send_udp/3`
- README: BEP 5 (Mainline DHT) row in Supported BEPs table

### Changed

- **Peer I/O:** `Peer.Sender` is the sole socket owner over `Peer.Transport`; `Peer.Receiver` removed; post-handshake socket handoff uses `Sender.activate/1`

### Fixed

- Torrent progress and `downloaded`/`left` counters reconciled with the on-disk bitfield
- Piece pipeline: idempotent piece statistics init, stale `:processing` cleanup, exclude-aware picker
- In-flight piece download recovery when subpiece requests stall (`waiting: []` no longer finishes early)
- Incoming piece block bounds validation; `Peer.log_id/1` for safe timeout logging
- Download scheduler: parallel piece picking with availability checks, resume handoff before controller scheduling, per-piece interested peer assignment

### Notes

- uTP (BEP 29) and DHT (BEP 5) are implemented and compiled in, but runtime activation (supervision wiring) is deferred to a future release; the default peer-acquisition/download path remains TCP + tracker-based.


## 0.3.0 - 2026-06-28

### Download location

- `ElixirTorrent.download/2` accepts an optional `:download_dir` keyword — base directory for downloaded files (defaults to `File.cwd!/0`)
- Session snapshots remain under `{File.cwd!()}/.elixir_torrent/state/` regardless of `:download_dir`
- `remove/2` with `delete_data: true` removes files from the torrent's download directory

### File layout

- Multi-file torrents whose files share no common top-level folder are written under a directory named after the torrent (sanitized `info.name`)
- Multi-file torrents that already use a shared root folder (e.g. `dir/a.bin`, `dir/b.bin`) keep their original paths
- Single-file torrents are written directly into the download root

### Docs

- README About section with project background

## 0.2.0 - 2026-06-11

### Session persistence

- Saved session state under `.elixir_torrent/state/{info_hash}.term` (relative to `File.cwd!/0`)
- On `download/1`, an existing session is loaded and the bitfield is verified against disk before resuming
- `remove/2` deletes the session file; `delete_data: true` also removes downloaded files

### Graceful shutdown API

- `stop_and_serialize/1` — stop piece downloads, disconnect peers (BEP 3), send tracker `event=stopped`, persist session, then stop the torrent process
- `stop_all_and_serialize/0` — same for every active torrent
- `list/0` — returns info hashes for all running torrent processes

### Peer disconnect

- Peers receive BEP 3 cancel / not interested / choke before TCP connections close
- Used during shutdown so peers are notified cleanly

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

