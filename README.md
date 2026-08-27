# ElixirTorrent

[![GitHub release](https://img.shields.io/badge/release-0.6.6-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent/releases/tag/0.6.6) [![Changelog](https://img.shields.io/badge/changelog-blue)](https://hexdocs.pm/elixir_torrent/changelog.html) [![Hex.pm](https://img.shields.io/hexpm/v/elixir_torrent.svg)](https://hex.pm/packages/elixir_torrent/0.6.6) [![HexDocs](https://img.shields.io/badge/hexdocs-0.6.6-8E44AD)](https://hexdocs.pm/elixir_torrent/0.6.6) [![Hex.pm Downloads](https://img.shields.io/hexpm/dt/elixir_torrent.svg)](https://hex.pm/packages/elixir_torrent) [![License](https://img.shields.io/hexpm/l/elixir_torrent.svg)](https://github.com/daniboybye/ElixirTorrent/blob/master/LICENSE)

[![build](https://img.shields.io/github/actions/workflow/status/daniboybye/ElixirTorrent/build-and-publish.yml?branch=master&label=build&logo=github)](https://github.com/daniboybye/ElixirTorrent/actions/workflows/build-and-publish.yml) [![codecov](https://codecov.io/gh/daniboybye/ElixirTorrent/branch/master/graph/badge.svg)](https://codecov.io/gh/daniboybye/ElixirTorrent) [![BEPs](https://img.shields.io/badge/BEPs-23%20implemented-E8A33D)](PROTOCOL.md) [![Last commit](https://img.shields.io/github/last-commit/daniboybye/ElixirTorrent/master)](https://github.com/daniboybye/ElixirTorrent/commits/master)

[![GitHub](https://img.shields.io/badge/source-ElixirTorrent-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent) [![Web UI](https://img.shields.io/badge/Web%20UI-ElixirTorrentWebUI-181717?logo=github)](https://github.com/daniboybye/ElixirTorrentWebUI) [![macOS](https://img.shields.io/badge/macOS-releases-silver?logo=apple)](https://github.com/daniboybye/ElixirTorrentWebUI/releases)

[![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/daniboybye/ElixirTorrent?label=openssf%20scorecard)](https://scorecard.dev/viewer/?uri=github.com/daniboybye/ElixirTorrent) [![OpenSSF Best Practices](https://img.shields.io/cii/level/14023?label=openssf%20best%20practices)](https://www.bestpractices.dev/projects/14023)

[![Elixir](https://img.shields.io/badge/elixir-%7E%3E%201.20-4B275F?logo=elixir)](https://elixir-lang.org) [![OTP](https://img.shields.io/badge/OTP-29-A90533?logo=erlang)](https://www.erlang.org)

**A complete BitTorrent client engine for Elixir/OTP** — downloads, seeds, resumes,
and traverses NAT, behind a small public API you can embed in your own application.

## About

This is a **fully functional BitTorrent client** that actually downloads torrents. It started as a course project for **Functional Programming with Elixir** at **Sofia University**. After the course ended, development continued in spare time until it was ready to publish on Hex.

The whole stack is Elixir on OTP primitives — wire protocol, DHT, trackers, piece
picking, storage, encryption — with [23 BEPs](PROTOCOL.md) implemented, encryption on
by default, IPv4/IPv6 dual stack, and interop verified against Transmission,
qBittorrent and libtorrent.

```elixir
{:ok, pid} = ElixirTorrent.download("/path/to/file.torrent")
{:ok, stats} = ElixirTorrent.stats(pid)
```

## What you get

- **Download and seed** — full BEP 3 peer protocol, fast extension (BEP 6), endgame,
  and automatic superseeding (BEP 16) when you are the only complete seed.
- **Find peers four ways** — trackers (HTTP + UDP, multitracker tiers), DHT (BEP 5,
  dual-stack via BEP 32/42), peer exchange (BEP 11), and LAN discovery (BEP 14).
  HTTP web seeds (BEP 19) act as a fifth data source.
- **Magnet links** — metadata fetched from peers over `ut_metadata` (BEP 9/10) and
  verified against the info hash before a normal session starts.
- **BitTorrent v2** (BEP 52) — pure-v2 torrents download and resume through their
  SHA-256 Merkle path; hybrid torrents join both swarms on the DHT.
- **Encryption** — MSE/PE is full and bidirectional, so encryption-only peers connect
  and ISP protocol throttling has nothing obvious to match on.
- **Works from behind a NAT** — uTP (BEP 29) alongside TCP, uTP hole punching
  (BEP 55), NAT-PMP/PCP/UPnP port mapping, and STUN-based NAT-type detection.
- **Resumable sessions** — bitfield and counters checkpoint every 30 s, so a crash
  costs a hash-check of what was in flight, not a full re-scan.
- **Built to stay small** — piece read/write/verify processes start on demand and
  idle-terminate instead of one live process per piece, and a measured per-family
  dial throttle stops the engine burning connections on an address family that is
  not reaching anyone.

Full per-BEP status, including the known gaps: **[PROTOCOL.md](PROTOCOL.md)**.

## Installation

```elixir
def deps do
  [
    {:elixir_torrent, "~> 0.6.6"}
  ]
end
```

```bash
mix deps.get
```

Requires **Elixir 1.20+**. The engine is an OTP application — start it before first
use (or list it in your supervision tree's dependencies):

```elixir
Application.ensure_all_started(:elixir_torrent)
```

## Quick start

### From a `.torrent` file

```elixir
{:ok, pid} = ElixirTorrent.download("/path/to/file.torrent")
[hash] = ElixirTorrent.list()

# Write files under a specific directory (session state still uses File.cwd!/0):
{:ok, pid} = ElixirTorrent.download("/path/to/file.torrent", download_dir: "/Downloads")

{:ok, stats} = ElixirTorrent.stats(pid, [:name, :speed, :downloaded, :bytes_size])
# stats.name, stats.speed.download, stats.speed.upload, …

files = ElixirTorrent.list_files(hash)
# Each entry has :path, :progress, :complete?, etc.
```

Poll `stats/2` while the download runs. When you are done, `stop_and_serialize/1`
keeps the progress and `remove/2` drops it.

### From a magnet link

```elixir
{:ok, pid} =
  ElixirTorrent.download_magnet(
    "magnet:?xt=urn:btih:…&tr=udp%3A%2F%2Ftracker.example.com%3A1337%2Fannounce"
  )
```

The engine parses the URI, announces to its `tr=` trackers and/or asks the DHT for
peers, fetches the `info` dictionary over BEP 9, checks `SHA1(bencode(info))` against
the magnet's hash, and only then starts a normal session.

A magnet needs **at least one `tr=` tracker or DHT enabled**; a trackerless magnet
with DHT off returns `{:error, :missing_trackers}`. Other common failures:
`:no_peers`, `:timeout`, `:metadata_unavailable`, `:info_hash_mismatch`.

## Session persistence

Progress survives restarts. Each session is a file under
`{File.cwd!()}/.elixir_torrent/state/{hex_info_hash}.term` holding the bitfield, byte
counters, and peer status. Call `download/2` with the same `.torrent` and the engine
loads the session, verifies pieces against what is on disk, and resumes from there.

```elixir
ElixirTorrent.stop_and_serialize(hash)   # one torrent
ElixirTorrent.stop_all_and_serialize()   # everything, e.g. on application shutdown
```

Stopping this way is a protocol-clean shutdown, not a socket drop: active piece
requests are cancelled, peers get BEP 3 `cancel`/`not interested`/`choke` before the
connection closes, and each tracker receives an `event=stopped` announce so the swarm
stops handing your address to other peers.

To drop a torrent instead of pausing it:

```elixir
ElixirTorrent.remove(hash)                      # deletes the session file
ElixirTorrent.remove(hash, delete_data: true)   # …and the downloaded files
```

## Configuration

Every subsystem that talks to the network can be switched off independently — useful
for embedded use, private-tracker-only setups, or a test suite that must not touch
the wire.

```elixir
config :elixir_torrent,
  listen_port: 6881

config :elixir_torrent, :dht,
  enabled: true,          # BEP 5 DHT
  routing_store: true,    # persist the routing table between runs
  bootstrap_routers: [{"router.bittorrent.com", 6881}]

config :elixir_torrent, :lsd, enabled: true     # BEP 14 LAN multicast discovery
config :elixir_torrent, :nat, enabled: true     # NAT-PMP/PCP/UPnP + STUN detection
config :elixir_torrent, :network, dial_scope: :any
```

`dial_scope: :this_host` restricts outbound connections to addresses this machine
owns (loopback and its own interfaces), which is how the test suite runs the full
engine against loopback fixtures without a single packet leaving the host.

## Public API

Full reference: [`hexdocs.pm/elixir_torrent/ElixirTorrent.html`](https://hexdocs.pm/elixir_torrent/ElixirTorrent.html)

| Function | Description |
| --- | --- |
| `download/2` | Start a download from a local `.torrent` path; optional `download_dir:` |
| `download_magnet/2` | Start from a magnet URI (metadata fetch + normal session) |
| `stats/2` | Runtime stats map (`:name`, `:speed`, `:downloaded`, `:bytes_size`, …) |
| `list/0` | Info hashes for all active torrent processes |
| `list_files/1` | Per-file paths and download progress |
| `stop_and_serialize/1` | Graceful stop + persist session |
| `stop_all_and_serialize/0` | Graceful stop + persist for every torrent |
| `remove/2` | Stop and drop from session; optional `delete_data: true` |
| `get/2` | Low-level field access (prefer `stats/2`) |
| `version/0` | Version-derived client peer ID prefix (`ET0-6-6`, BEP 20) |

## ElixirTorrent Web (desktop app)

Need a client rather than a library? **[ElixirTorrent Web](https://github.com/daniboybye/ElixirTorrentWebUI)**
is the official Phoenix LiveView UI for this engine, shipped as a native macOS app.

## Development

```bash
mix test          # full suite; runs with no network access
mix quality       # compile --warnings-as-errors + dialyzer + credo --strict + sobelow
```

`mix quality` is the same gate CI runs. Sobelow does security-focused static
analysis at `--threshold medium`, filtering low-confidence file-path findings from
the engine's own already-sanitized path handling.

The package also builds a small escript for ad-hoc testing:

```bash
mix escript.build
./elixir_torrent
# then type: download /path/to/file.torrent
```

The escript's interactive loop does not expose magnet links yet — use
`download_magnet/2` from your own application for those.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Security reports
go through [SECURITY.md](SECURITY.md), not public issues.

Released under the [MIT License](https://github.com/daniboybye/ElixirTorrent/blob/master/LICENSE).
