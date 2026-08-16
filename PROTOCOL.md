# Protocol support

ElixirTorrent implements **23 BEPs** plus the two de-facto specs every modern
client needs (magnet URIs and MSE/PE encryption). This page is the honest,
per-BEP account of what is wired into the download and seed paths, what is
partial, and what is still missing — the same table the maintainer works from.

## Status meanings

| Status | Meaning |
| --- | --- |
| **Full** | Used in normal download and seeding paths |
| **Partial** | Implemented for common cases; known gaps listed |
| **Magnet only** | Implemented only for magnet metadata fetch, not general peer sessions |
| **Not implemented** | Planned or acknowledged gap |

## BEPs

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
| [BEP 20](https://www.bittorrent.org/beps/bep_0020.html) | Peer ID conventions | **Full** | Version-derived prefix (`ET0-6-4` for package 0.6.4); one runtime-generated 20-byte identity per application instance |
| [BEP 23](https://www.bittorrent.org/beps/bep_0023.html) | Compact peer lists | **Full** | Compact IPv4 peers and dictionary-model IP literals; malformed values are ignored, while legacy dictionary hostnames are intentionally not DNS-resolved; combined with BEP 7 for `peers6` |
| [BEP 24](https://www.bittorrent.org/beps/bep_0024.html) | Tracker returns external IP | **Partial** | Decodes `external ip` from HTTP responses; not used for listen-address selection |
| [BEP 29](https://www.bittorrent.org/beps/bep_0029.html) | Micro Transport Protocol (uTP) | **Substantially Full** | SYN/STATE/DATA/FIN, LEDBAT, cumulative and selective ACK with SACK fast-loss recovery, owner-buffer-aware receive windows, type-preserving retransmission, symmetric FIN close, and dead zero-window probing; TCP-first dial with uTP fallback over DHT's shared UDP socket |
| [BEP 31](https://www.bittorrent.org/beps/bep_0031.html) | Failure retry extension | **Full** | Honors bencoded `retry in` on 2xx and non-2xx HTTP failures; converts BEP minutes to per-tracker cooldown deadlines so tier siblings continue normally; `never` disables the URL |
| [BEP 32](https://www.bittorrent.org/beps/bep_0032.html) | IPv6 DHT extension | **Full** | Separate v4/v6 k-bucket routing tables; symmetric `want` support for find_node/get_peers; absent `want` and peer `values` follow the query socket family; dedicated global-IPv6 UDP socket for KRPC and uTP egress |
| [BEP 42](https://www.bittorrent.org/beps/bep_0042.html) | DHT security extension (IP-derived node ID) | **Full** | Network-order CRC32C node IDs; family-local inbound validation on query sources, responses, compact contacts, persisted contacts and announce tokens; local/private exemption; top-level KRPC `ip` observation |
| [BEP 48](https://www.bittorrent.org/beps/bep_0048.html) | Tracker scrape convention | **Full** | HTTP scrape URLs are derived only from an exact trailing `/announce` path segment, preserving private-tracker query/passkey authentication, and `info_hash` is appended; bencoded `files` decode and UDP BEP 15 scrape are supported; the tested 5 min health cache skips fresh `{0, 0}` dead-swarm URLs so a fully-dead tier falls through |
| [BEP 52](https://www.bittorrent.org/beps/bep_0052.html) | BitTorrent v2 (SHA-256 + merkle trees) | **Partial** | Phases 1–5/6: pure-v2 `.torrent` download/resume is complete with piece-aligned file-tree storage, Merkle verification, and the truncated SHA-256 swarm identity. Hybrid hash serving (IDs 21–23) is fixture-tested through the disk-backed responder, and hybrid DHT discovery joins both its v1 and truncated-v2 swarms while retaining one v1-keyed local swarm and SHA-1 piece path. Tracker dual-announce, pure-v2 magnets/webseeds, and phase-6 live libtorrent/qBittorrent interop remain; live interop has not been attempted |
| [BEP 55](https://www.bittorrent.org/beps/bep_0055.html) | uTP hole punching (`ut_holepunch`) | **Substantially Full** | IPv4/IPv6 rendezvous, connect and typed-error codec; PEX-informed relay preference with supporting-peer fallback; relay sends each side the other endpoint; uTP punch on `connect`; silent non-supporting/already-connected guards; per-peer inbound rate limit; relay errors preserve the per-target 30s/2m/8m cooldown and max 4/session; symmetric-NAT guard correctly skips initiating while retaining the relay role |

## Beyond the numbered BEPs

**MSE/PE (Message Stream Encryption / Protocol Encryption)** — the Vuze de-facto
spec, not a numbered BEP. **Full, bidirectional.** 768-bit MODP Diffie–Hellman key
exchange, RC4 stream cipher, SHA-1 key derivation (all via OTP `:crypto`). Inbound
connections auto-detect plaintext vs encrypted; outbound prefers the encrypted
handshake and falls back to plaintext, honouring the peer's `crypto_select` (RC4 or
plaintext) for the post-handshake stream. Interop-verified against Transmission,
qBittorrent, and libtorrent. Provides ISP-throttling resistance and connectivity
with encryption-only peers.

**Magnet URIs** are a de-facto convention (BitTorrent wiki), not a numbered BEP.
We parse `xt=urn:btih:` (hex and base32), multiple `tr=`, and optional `dn=`.

**De-facto tracker behaviour:** before metadata is known, magnet announces use
`left=16384` (typical client convention, not a BEP requirement) so trackers return
peers that support `ut_metadata`.

## Not yet implemented

| Priority | Item | Why it matters |
| --- | --- | --- |
| Medium | **BEP 7 — full multi-homed announce** | Announce separately from every eligible local listen address, beyond the current one primary address per family |
| Medium | **BEP 52 phase 6 — pure-v2 interop** | Verify the Phase 5 `.torrent` path against live libtorrent/qBittorrent peers, then add pure-v2 magnet and webseed support |

BEP 17 (HTTP seeding, Hoffman-style) is not planned — BEP 19 covers the web-seed
case that clients actually publish.
