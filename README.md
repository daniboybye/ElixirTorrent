# ElixirTorrent

[![GitHub release](https://img.shields.io/badge/release-0.6.0-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent/releases/tag/0.6.0) [![Hex.pm](https://img.shields.io/hexpm/v/elixir_torrent.svg)](https://hex.pm/packages/elixir_torrent/0.6.0) [![HexDocs](https://img.shields.io/badge/hexdocs-0.6.0-8E44AD)](https://hexdocs.pm/elixir_torrent/0.6.0) [![Changelog](https://img.shields.io/badge/changelog-blue)](https://hexdocs.pm/elixir_torrent/changelog.html) [![GitHub](https://img.shields.io/badge/source-ElixirTorrent-181717?logo=github)](https://github.com/daniboybye/ElixirTorrent) [![CI](https://img.shields.io/github/actions/workflow/status/daniboybye/ElixirTorrent/build-and-publish.yml?branch=master&label=CI&logo=github)](https://github.com/daniboybye/ElixirTorrent/actions/workflows/build-and-publish.yml) [![codecov](https://codecov.io/gh/daniboybye/ElixirTorrent/branch/master/graph/badge.svg)](https://codecov.io/gh/daniboybye/ElixirTorrent) [![Last commit](https://img.shields.io/github/last-commit/daniboybye/ElixirTorrent/master)](https://github.com/daniboybye/ElixirTorrent/commits/master) [![Web UI](https://img.shields.io/badge/Web%20UI-ElixirTorrentWebUI-181717?logo=github)](https://github.com/daniboybye/ElixirTorrentWebUI) [![macOS](https://img.shields.io/badge/macOS-releases-silver?logo=apple)](https://github.com/daniboybye/ElixirTorrentWebUI/releases)

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
    {:elixir_torrent, "~> 0.6.0"}
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

It compiles with warnings as errors, runs Dialyzer, and runs `mix credo --strict --all`.
The same strict Credo gate runs in CI, covering every enabled check at every priority.

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
| `version/0` | Version-derived client peer ID prefix (`ET0-6-0`, BEP 20) |

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
| [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) | BitTorrent peer protocol | **Full** | Handshake, choke/unchoke, request/cancel, strict bitfield spare-bit validation, actual per-piece upload bounds, endgame |
| [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) | HTTP tracker announce | **Full** | `compact=1`; existing private-tracker query/passkey authentication is preserved before generated announce parameters; one-shot `started`/`completed` and shutdown `stopped`; routine and resumed announces omit `event`; stats fields |
| [BEP 4](https://www.bittorrent.org/beps/bep_0004.html) | Known number allocations | **Full** | Message IDs and reserved bits as used |
| [BEP 5](https://www.bittorrent.org/beps/bep_0005.html) | DHT | **Substantially Full** | KRPC over UDP with error 204 for unknown methods; k-buckets with two-strike health and ping-before-evict; iterative peer lookup and iterative-to-self bootstrap; token validation; NAT-friendly `implied_port`; BT PORT; persisted BEP 32 dual-stack routing. Remaining strict gap: a first-seen inbound-only query source is still promoted before response reachability is proven |
| [BEP 6](https://www.bittorrent.org/beps/bep_0006.html) | Fast extension | **Full** | Fast-negotiated handshake availability, `allowed_fast`, verified-piece suggestions, and exactly-one `piece`/`reject` handling; choke rejects queued non-allowed requests after the choke |
| [BEP 7](https://www.bittorrent.org/beps/bep_0007.html) | IPv6 tracker extension | **Partial** | Parses `peers6`; source-bound HTTP/UDP announce from one primary IPv4 and one primary global IPv6 address — full per-listen-address multi-homing remains |
| [BEP 9](https://www.bittorrent.org/beps/bep_0009.html) | Extension for Peers to Send Metadata Files | **Full** | Bencoded `ut_metadata` request/data/reject, 16 KiB pieces, multi-peer fetch, SHA-1 verification (magnet bootstrap); completed torrents serve metadata to magnet leechers |
| [BEP 10](https://www.bittorrent.org/beps/bep_0010.html) | Extension Protocol | **Full** | Bounded LTEP transport: non-blocking id-0 negotiation, per-peer one-byte `m` ids, additive live re-handshake/disable, unknown-id ignore, and validated extension registration |
| [BEP 11](https://www.bittorrent.org/beps/bep_0011.html) | Peer exchange (ut_pex) | **Partial** | Private-torrent isolation; IPv4/IPv6 flags and bounded codec; per-connection initial snapshots + 60 s deltas; source-owned drops; recent-peer supplement; rate/filter/retention bounds; BEP 40 ordering; magnet-fetch ingest. Live libtorrent/qBittorrent v4+v6 and private-traffic interop remains unverified |
| [BEP 12](https://www.bittorrent.org/beps/bep_0012.html) | Multitracker metadata | **Partial (deliberate)** | Shuffles each tier once at load, keeps working trackers sticky, and promotes a backup after the whole active tier yields no peers. Below the swarm target, deliberately fans out up to four tiers concurrently to avoid black-hole tracker serialization under CGNAT; at/above target, BEP-ordered single-tier failover applies |
| [BEP 14](https://www.bittorrent.org/beps/bep_0014.html) | Local Service Discovery | **Full** | Per-interface IPv4 `239.192.152.143:6771` and IPv6 `[ff15::efc0:988f]:6771` multicast for active public torrents; cookie self-filtering and multi-torrent batches paced globally to at most one announce per minute |
| [BEP 15](https://www.bittorrent.org/beps/bep_0015.html) | UDP tracker protocol | **Full** | Connect, announce, scrape, error packets; 60 s connection_id cache; full 15×2ⁿ s long-announce ladder reconnects after expiry, while scrape and under-target fast-fail use intentionally shorter ladders; compact IPv4/IPv6 peers |
| [BEP 16](https://www.bittorrent.org/beps/bep_0016.html) | Superseeding | **Full** | Automatically enters initial-seed mode when a live download completes with no confirmed remote seed: one rare fabricated `have` per peer, assignment rotation on propagation, hidden-piece rejection, and normal seeding restored for a complete remote bitfield or after restart |
| [BEP 19](https://www.bittorrent.org/beps/bep_0019.html) | WebSeed — HTTP/FTP seeding (GetRight-style) | **Partial** | HTTP/HTTPS `Range` fetches for v1/hybrid torrents share the peer verify/write path, with corrupt mirrors disabled per session; FTP, GetRight gap scheduling, and pure-v2 mapping are not implemented; BEP 17 is not planned |
| [BEP 20](https://www.bittorrent.org/beps/bep_0020.html) | Peer ID conventions | **Full** | Version-derived prefix (`ET0-6-0` for package 0.6.0); one runtime-generated 20-byte identity per application instance |
| [BEP 23](https://www.bittorrent.org/beps/bep_0023.html) | Compact peer lists | **Full** | Compact IPv4 peers and dictionary-model IP literals; malformed values are ignored, while legacy dictionary hostnames are intentionally not DNS-resolved; combined with BEP 7 for `peers6` |
| [BEP 24](https://www.bittorrent.org/beps/bep_0024.html) | Tracker returns external IP | **Partial** | Decodes `external ip` from HTTP responses; not used for listen-address selection |
| [BEP 29](https://www.bittorrent.org/beps/bep_0029.html) | Micro Transport Protocol (uTP) | **Substantially Full** | SYN/STATE/DATA/FIN, LEDBAT, cumulative and selective ACK with SACK fast-loss recovery, owner-buffer-aware receive windows, type-preserving retransmission, symmetric FIN close, and dead zero-window probing; TCP-first dial with uTP fallback over DHT's shared UDP socket |
| [BEP 31](https://www.bittorrent.org/beps/bep_0031.html) | Failure retry extension | **Full** | Honors bencoded `retry in` on 2xx and non-2xx HTTP failures; converts BEP minutes to per-tracker cooldown deadlines so tier siblings continue normally; `never` disables the URL |
| [BEP 32](https://www.bittorrent.org/beps/bep_0032.html) | IPv6 DHT extension | **Full** | Separate v4/v6 k-bucket routing tables; symmetric `want` support for find_node/get_peers; absent `want` and peer `values` follow the query socket family; dedicated global-IPv6 UDP socket for KRPC and uTP egress |
| [BEP 42](https://www.bittorrent.org/beps/bep_0042.html) | DHT security extension (IP-derived node ID) | **Full** | Network-order CRC32C node IDs; family-local inbound validation on query sources, responses, compact contacts, persisted contacts and announce tokens; local/private exemption; top-level KRPC `ip` observation |
| [BEP 48](https://www.bittorrent.org/beps/bep_0048.html) | Tracker scrape convention | **Full** | `Tracker.scrape/2` derives HTTP scrape only from an exact trailing `/announce` path segment, preserves private-tracker query/passkey authentication, and appends `info_hash`; bencoded `files` decode and UDP BEP 15 scrape are supported; the tested 5 min health cache skips fresh `{0, 0}` dead-swarm URLs so a fully-dead tier falls through |
| [BEP 52](https://www.bittorrent.org/beps/bep_0052.html) | BitTorrent v2 (SHA-256 + merkle trees) | **Partial** | Phases 1–5/6: pure-v2 `.torrent` download/resume is complete with piece-aligned file-tree storage, Merkle verification, and the truncated SHA-256 swarm identity. Hybrid hash serving (IDs 21–23) is fixture-tested through the disk-backed responder, and hybrid DHT discovery joins both its v1 and truncated-v2 swarms while retaining one v1-keyed local swarm and SHA-1 piece path. Tracker dual-announce, pure-v2 magnets/webseeds, and phase-6 live libtorrent/qBittorrent interop remain; live interop has not been attempted |
| [BEP 55](https://www.bittorrent.org/beps/bep_0055.html) | uTP hole punching (`ut_holepunch`) | **Substantially Full** | IPv4/IPv6 rendezvous, connect and typed-error codec; PEX-informed relay preference with supporting-peer fallback; relay sends each side the other endpoint; uTP punch on `connect`; silent non-supporting/already-connected guards; per-peer inbound rate limit; relay errors preserve the per-target 30s/2m/8m cooldown and max 4/session; symmetric-NAT guard correctly skips initiating while retaining the relay role |

**Magnet URIs** are a de-facto convention (BitTorrent wiki), not a numbered BEP. We parse `xt=urn:btih:` (hex and base32), multiple `tr=`, and optional `dn=`.

**De-facto tracker behaviour:** before metadata is known, magnet announces use `left=16384` (typical client convention, not a BEP requirement) so trackers return peers that support `ut_metadata`.

**MSE/PE (Message Stream Encryption / Protocol Encryption)** — the Vuze de-facto spec, not a numbered BEP. **Full, bidirectional.** 768-bit MODP Diffie–Hellman key exchange, RC4 stream cipher, SHA-1 key derivation (all via OTP `:crypto`). Inbound connections auto-detect plaintext vs encrypted; outbound prefers the encrypted handshake and falls back to plaintext, honouring the peer's `crypto_select` (RC4 or plaintext) for the post-handshake stream. Interop-verified against Transmission, qBittorrent, and libtorrent. Provides ISP-throttling resistance and connectivity with encryption-only peers.

## Recently completed (2026-07)

- **PEX parity hardening (BEP 10/11/27/40)** — private torrents no longer negotiate or process PEX; public peers exchange bounded per-connection snapshots with real flags, source-owned drops, recent-peer supplementation, abuse filtering, canonical priority, and magnet-fetch ingestion. Status remains Partial pending live libtorrent/qBittorrent v4+v6 and private zero-traffic verification.
- **Superseeding (BEP 16)** — a newly completed sole seed hides its full bitfield and assigns one rare piece per peer until the swarm produces another complete seed, reducing redundant initial uploads.
- **Web seeds (BEP 19)** — HTTP/URL seeding as a third data source alongside peers and DHT, sharing the same piece-verify and write path as a normal download.
- **Local Service Discovery (BEP 14)** — LAN peer discovery via UDP multicast, no tracker/DHT round-trip needed.
- **BitTorrent v2 download + hybrid discovery (BEP 52, phases 1–5/6)** — pure-v2 `.torrent` files download and resume through the truncated SHA-256 swarm and per-file Merkle path; hybrid torrents serve fixture-verified hash proofs and query/announce on DHT under both identities without splitting their v1-keyed local swarm.
- **DHT secure node ID (BEP 42)** — node IDs are bound to their IPv4/IPv6 address, and non-compliant remote contacts cannot become trusted routing or announce targets (Sybil/routing-poisoning mitigation).
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
| Medium | **BEP 7 — full multi-homed announce** | Announce separately from every eligible local listen address, beyond the current one primary address per family |
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
