# ElixirTorrent

[![GitHub release](https://img.shields.io/badge/release-0.5.1-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent/releases/tag/0.5.1) [![Hex.pm](https://img.shields.io/hexpm/v/elixir_torrent.svg)](https://hex.pm/packages/elixir_torrent/0.5.1) [![HexDocs](https://img.shields.io/badge/hexdocs-0.5.1-8E44AD)](https://hexdocs.pm/elixir_torrent/0.5.1) [![Changelog](https://img.shields.io/badge/changelog-blue)](https://hexdocs.pm/elixir_torrent/changelog.html) [![GitHub](https://img.shields.io/badge/source-ElixirTorrent-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent) [![Web UI](https://img.shields.io/badge/Web%20UI-ElixirTorrentWebUI-181717?logo=github)](https://github.com/daniboybye/ElixirTorrentWebUI) [![macOS](https://img.shields.io/badge/macOS-releases-silver?logo=apple)](https://github.com/daniboybye/ElixirTorrentWebUI/releases)

BitTorrent client **engine** for Elixir/OTP — embed downloads in your own app with a small, stable public API.

## About

This is a **fully functional BitTorrent client** that actually downloads torrents — not a stub or protocol sketch. It started as a course project for **Functional Programming with Elixir** at **Sofia University**. After the course ended, development continued in spare time until it was ready to publish on Hex.

## ElixirTorrent Web (desktop app)

Need a full client, not just the library? **[ElixirTorrent Web](https://github.com/daniboybye/ElixirTorrentWebUI)**
is the official Phoenix LiveView UI for this engine, shipped as a native macOS desktop app.

The sections below cover the **engine API** for Elixir developers embedding BitTorrent in their own apps.

## Installation

Add `elixir_torrent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:elixir_torrent, "~> 0.5.1"}
  ]
end
```

Then fetch and start the application:

```bash
mix deps.get
```

```elixir
# In your Application.start/2 or before first use:
Application.ensure_all_started(:elixir_torrent)
```

Requires **Elixir 1.20+**.

### Development quality checks

Run the project quality gate with:

```bash
mix quality
```

It compiles with warnings as errors, runs Dialyzer, and runs Credo's warning-level checks. Use
`mix credo --strict` when auditing the existing readability and refactoring backlog.

## Quick start

### From a `.torrent` file

```elixir
Application.ensure_all_started(:elixir_torrent)

{:ok, pid} = ElixirTorrent.download("/path/to/file.torrent")
[hash] = ElixirTorrent.list()

# Optional: write files under a specific directory (session state still uses File.cwd!/0)
{:ok, pid} = ElixirTorrent.download("/path/to/file.torrent", download_dir: "/Downloads")

{:ok, stats} =
  ElixirTorrent.stats(pid, [:name, :speed, :downloaded, :bytes_size])

# stats.name, stats.speed.download, stats.speed.upload, …

files = ElixirTorrent.list_files(hash)
# Each entry has :path, :progress, :complete?, etc.
```

Poll `stats/2` while the download runs. When you are done monitoring, call
`stop_and_serialize/1` (see below) or `remove/2` to drop the torrent from the active session.

### From a magnet link

```elixir
{:ok, pid} =
  ElixirTorrent.download_magnet(
    "magnet:?xt=urn:btih:…&tr=udp%3A%2F%2Ftracker.example.com%3A1337%2Fannounce"
  )
```

The magnet flow:

1. Parse the URI (`xt=urn:btih:`, `tr=`, optional `dn=`).
2. Announce to `tr=` tracker URLs when present, and/or discover peers via **BEP 5 DHT** when enabled.
3. Fetch the `info` dictionary from a peer via **BEP 9** (`ut_metadata`), negotiated with **BEP 10** (LTEP).
4. Verify `SHA1(bencode(info))` matches the magnet hash.
5. Write a temporary `.torrent` file and start a normal session via `download/1`.

**Requirements:** at least one `tr=` tracker URL **or** DHT enabled (default on desktop). Trackerless magnets with DHT disabled return `{:error, :missing_trackers}`.

Common errors: `:no_peers`, `:timeout`, `:metadata_unavailable`, `:info_hash_mismatch`.

## Session persistence

The engine can save and restore download progress across process restarts.

**On disk:** `{File.cwd!()}/.elixir_torrent/state/{hex_info_hash}.term`

Each file stores the bitfield, byte counters, and peer status. When you call
`download/1` with a `.torrent` that was previously saved, the engine loads the
session, verifies pieces against disk, and resumes from the saved bitfield.

**Persist before exit:**

```elixir
ElixirTorrent.stop_and_serialize(hash)
# or, for every active torrent:
ElixirTorrent.stop_all_and_serialize()
```

**Remove without keeping progress:**

```elixir
ElixirTorrent.remove(hash)
# also delete downloaded files:
ElixirTorrent.remove(hash, delete_data: true)
```

`remove/2` deletes the session file. `stop_and_serialize/1` writes a fresh snapshot and keeps the torrent removable on the next boot via the same `.torrent` path.

## Graceful shutdown

`stop_and_serialize/1` runs, in order:

1. Stop active piece downloads
2. Disconnect all peers (BEP 3 cancel / not interested / choke, then TCP close)
3. Send tracker announce with `event=stopped`
4. Write session state to `.elixir_torrent/state/`
5. Stop the torrent OTP process

Use this when your application shuts down and you want downloads to resume later.
`stop_all_and_serialize/0` applies the same steps to every running torrent.

## Public API

Full reference: [`hexdocs.pm/elixir_torrent/ElixirTorrent.html`](https://hexdocs.pm/elixir_torrent/ElixirTorrent.html)

| Function | Description |
| --- | --- |
| `download/2` | Start a download from a local `.torrent` path; optional `download_dir:` |
| `download_magnet/1` | Start from a magnet URI (metadata fetch + normal session); returns `{:ok, pid}` |
| `stats/2` | Runtime stats map (`:name`, `:speed`, `:downloaded`, `:bytes_size`, …) |
| `list/0` | Info hashes for all active torrent processes |
| `list_files/1` | Per-file paths and download progress |
| `stop_and_serialize/1` | Graceful stop + persist session |
| `stop_all_and_serialize/0` | Graceful stop + persist for every torrent |
| `remove/2` | Stop and drop from session; optional `delete_data: true` |
| `get/2` | Low-level field access (prefer `stats/2`) |
| `version/0` | Client peer ID prefix (`ET0-3-0`, BEP 20) |

## Protocol support (BEPs)

Status meanings:

| Status | Meaning |
| --- | --- |
| **Full** | Used in normal download and seeding paths |
| **Partial** | Implemented for common cases; known gaps listed |
| **Magnet only** | Implemented only for magnet metadata fetch, not general peer sessions |
| **Not implemented** | Planned or acknowledged gap |

| BEP | Topic | Status | Notes |
| --- | --- | --- | --- |
| [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) | BitTorrent peer protocol | **Full** | Handshake, choke/unchoke, request/cancel, bitfield, endgame |
| [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) | HTTP tracker announce | **Full** | `compact=1`, events, stats fields |
| [BEP 4](https://www.bittorrent.org/beps/bep_0004.html) | Known number allocations | **Full** | Message IDs and reserved bits as used |
| [BEP 5](https://www.bittorrent.org/beps/bep_0005.html) | DHT | **Full** | KRPC over UDP (ping, find_node, get_peers, announce_peer), k-buckets, bootstrap routers, iterative lookup, token validation, BT PORT message + reserved bit; trackerless magnets when enabled; BEP 32 IPv6 routing tables + dedicated v6 socket; routing table persisted across restarts (node id + bucket contents) for fast rejoin |
| [BEP 6](https://www.bittorrent.org/beps/bep_0006.html) | Fast extension | **Full** | `allowed_fast`, `suggest_piece`, reject on choked requests |
| [BEP 7](https://www.bittorrent.org/beps/bep_0007.html) | IPv6 tracker extension | **Partial** | Parses `peers6`; HTTP/UDP announce over one IPv4 and one IPv6 source address each — not full multi-homed announce per listen address |
| [BEP 9](https://www.bittorrent.org/beps/bep_0009.html) | Extension for Peers to Send Metadata Files | **Full** | Bencoded `ut_metadata` request/data/reject, 16 KiB pieces, multi-peer fetch, SHA-1 verification (magnet bootstrap); completed torrents serve metadata to magnet leechers |
| [BEP 10](https://www.bittorrent.org/beps/bep_0010.html) | Extension Protocol | **Full** | Reusable LTEP layer (`Peer.LTEP`): reserved bit, extended message 20, handshake encode/decode/merge, per-peer `m` id mapping, extension registry; `ut_metadata` wired for magnet bootstrap and seed serving |
| [BEP 11](https://www.bittorrent.org/beps/bep_0011.html) | Peer exchange (ut_pex) | **Full** | Encode/decode, ingest, and broadcast over LTEP |
| [BEP 12](https://www.bittorrent.org/beps/bep_0012.html) | Multitracker metadata | **Full** | Preserves `announce-list` tier structure; sequential tier failover; promotes working tracker within tier |
| [BEP 14](https://www.bittorrent.org/beps/bep_0014.html) | Local Service Discovery | **Full** | UDP multicast on 239.192.152.143:6771, `BT-SEARCH` broadcast every 5 min for active public torrents; IPv6 group deferred |
| [BEP 15](https://www.bittorrent.org/beps/bep_0015.html) | UDP tracker protocol | **Full** | Connect, announce, scrape, error packets; connection_id cache; 15×2ⁿ s backoff; compact IPv4/IPv6 peers |
| [BEP 16](https://www.bittorrent.org/beps/bep_0016.html) | Superseeding | **Full** | Automatically enters initial-seed mode when a live download completes with no confirmed remote seed: one rare fabricated `have` per peer, assignment rotation on propagation, hidden-piece request rejection, and normal seeding restored when a remote peer holds the full torrent |
| [BEP 19](https://www.bittorrent.org/beps/bep_0019.html) | WebSeed — HTTP/FTP seeding (GetRight-style) | **Partial** | HTTP/HTTPS `Range` fetches for v1/hybrid torrents share the peer verify/write path, with corrupt mirrors disabled per session; FTP, GetRight gap scheduling, and pure-v2 mapping are not implemented; BEP 17 is not planned |
| [BEP 20](https://www.bittorrent.org/beps/bep_0020.html) | Peer ID conventions | **Full** | Prefix `ET0-3-0` |
| [BEP 23](https://www.bittorrent.org/beps/bep_0023.html) | Compact peer lists | **Full** | Compact IPv4 peers; combined with BEP 7 for `peers6` |
| [BEP 24](https://www.bittorrent.org/beps/bep_0024.html) | Tracker returns external IP | **Partial** | Decodes `external ip` from HTTP responses; not used for listen-address selection |
| [BEP 29](https://www.bittorrent.org/beps/bep_0029.html) | Micro Transport Protocol (uTP) | **Full** | Packet stack with LEDBAT; TCP-first dial with uTP fallback; shared UDP socket with DHT |
| [BEP 31](https://www.bittorrent.org/beps/bep_0031.html) | Failure retry extension | **Full** | Honors bencoded `retry in` on 2xx and non-2xx HTTP failures; converts BEP minutes to per-tracker cooldown deadlines so tier siblings continue normally; `never` disables the URL |
| [BEP 32](https://www.bittorrent.org/beps/bep_0032.html) | IPv6 DHT extension | **Full** | Separate v4/v6 k-bucket routing tables; symmetric `want` support for find_node/get_peers; absent `want` and peer `values` follow the query socket family; dedicated global-IPv6 UDP socket for KRPC and uTP egress |
| [BEP 42](https://www.bittorrent.org/beps/bep_0042.html) | DHT security extension (IP-derived node ID) | **Full** | CRC32C-bound node id prefix from the primary global IPv6 (falls back to random); Sybil/routing-poisoning mitigation |
| [BEP 48](https://www.bittorrent.org/beps/bep_0048.html) | Tracker scrape convention | **Full** | `Tracker.scrape/2` for HTTP (BEP 48 `/scrape` URL derivation, bencoded `files` map) and UDP (BEP 15 scrape packet, prefer IPv6 host); periodic 5 min per-torrent scrape loop caches `{seeders, leechers, completed}` per tracker; dead-swarm URLs ({0, 0} within 20 min) skipped at announce time so a fully-dead tier falls through to the next tier |
| [BEP 52](https://www.bittorrent.org/beps/bep_0052.html) | BitTorrent v2 (SHA-256 + merkle trees) | **Partial** | Phases 1–5/6: pure-v2 `.torrent` download/resume is complete with piece-aligned file-tree storage, Merkle verification, and the truncated SHA-256 swarm identity. Hybrid hash serving (IDs 21–23) is fixture-tested through the disk-backed responder, and hybrid DHT discovery joins both its v1 and truncated-v2 swarms while retaining one v1-keyed local swarm and SHA-1 piece path. Tracker dual-announce, pure-v2 magnets/webseeds, and phase-6 live libtorrent/qBittorrent interop remain; live interop has not been attempted |
| [BEP 55](https://www.bittorrent.org/beps/bep_0055.html) | uTP hole punching (`ut_holepunch`) | **Full** | LTEP extension id 3; binary rendezvous/connect/error codec for IPv4 **and** IPv6; relay role sends `connect` to both endpoints or a typed error reply (`no_such_peer`/`not_connected`/`no_support`/`no_self`) to the initiator; uTP punch dial on `connect`; outbound trigger after direct dial failure for both families; per-target exponential backoff (30s/2m/8m, max 4/session); symmetric-NAT guard skips initiating when STUN classifies our mapping as endpoint-dependent |

**Magnet URIs** are a de-facto convention (BitTorrent wiki), not a numbered BEP. We parse `xt=urn:btih:` (hex and base32), multiple `tr=`, and optional `dn=`.

**De-facto tracker behaviour:** before metadata is known, magnet announces use `left=16384` (typical client convention, not a BEP requirement) so trackers return peers that support `ut_metadata`.

**MSE/PE (Message Stream Encryption / Protocol Encryption)** — the Vuze de-facto spec, not a numbered BEP. **Full, bidirectional.** 768-bit MODP Diffie–Hellman key exchange, RC4 stream cipher, SHA-1 key derivation (all via OTP `:crypto`). Inbound connections auto-detect plaintext vs encrypted; outbound prefers the encrypted handshake and falls back to plaintext, honouring the peer's `crypto_select` (RC4 or plaintext) for the post-handshake stream. Interop-verified against Transmission, qBittorrent, and libtorrent. Provides ISP-throttling resistance and connectivity with encryption-only peers.

## Recently completed (2026-07)

- **Superseeding (BEP 16)** — a newly completed sole seed hides its full bitfield and assigns one rare piece per peer until the swarm produces another complete seed, reducing redundant initial uploads.
- **Web seeds (BEP 19)** — HTTP/URL seeding as a third data source alongside peers and DHT, sharing the same piece-verify and write path as a normal download.
- **Local Service Discovery (BEP 14)** — LAN peer discovery via UDP multicast, no tracker/DHT round-trip needed.
- **BitTorrent v2 download + hybrid discovery (BEP 52, phases 1–5/6)** — pure-v2 `.torrent` files download and resume through the truncated SHA-256 swarm and per-file Merkle path; hybrid torrents serve fixture-verified hash proofs and query/announce on DHT under both identities without splitting their v1-keyed local swarm.
- **DHT secure node ID (BEP 42)** — node id cryptographically bound to our own IP (Sybil/routing-poisoning mitigation).
- **BEP 48 scrape-driven tracker health** — every torrent scrapes its trackers periodically for `{seeders, leechers}` and skips confirmed dead-swarm URLs at announce time, so a tier of dead trackers falls through to the next tier instead of firing a wasted parallel announce every 30 s while under swarm target.
- **Magnet x.pe hand-off** — magnet-embedded fallback peers stay live candidates for the whole session instead of being dropped once metadata fetch completes.
- **Mid-download session checkpoint** — bitfield + counters persisted every 30 s, so a crash resumes with a hash-check of only what's unconfirmed, not a full re-scan.
- **MSE/PE encryption** (full bidirectional — see the note above).
- **Measured per-family dial throttle** — de-prioritises the address family with proven-low outbound success (data-driven; under CGNAT+IPv6 that is IPv4 at ~1.3% vs IPv6 ~25%), without starving single-family swarms.
- **Lazy piece storage** — piece read/write/verify processes start on demand and idle-terminate instead of one persistent process per piece, cutting process count and memory to a fraction (compact-state model like libtorrent/qBittorrent).
- **DHT routing-table persistence** across restarts for fast rejoin.

## Not yet implemented (roadmap)

Work tracked for future releases:

| Priority | Item | Why it matters |
| --- | --- | --- |
| Medium | **BEP 7 — full multi-homed announce** | Announce per local listen address (v4/v6), filter link-local/loopback, correct source-IP bind for HTTP and UDP |
| Medium | **BEP 52 phase 6 — pure-v2 interop** | Verify the Phase 5 `.torrent` path against live libtorrent/qBittorrent peers, then add pure-v2 magnet and webseed support |

Full internal backlog and design rationale live in [`.claude/PLAN.md`](.claude/PLAN.md) and [`.claude/ARCHITECTURE.md`](.claude/ARCHITECTURE.md) (kept in sync with this table).

## CLI (escript)

The package builds an escript for ad-hoc testing:

```bash
mix escript.build
./elixir_torrent
# then type: download /path/to/file.torrent
```

The escript does not expose `download_magnet` in the interactive loop yet — use the API from your OTP application for magnet links.

For production use, call the API from your OTP application instead.
