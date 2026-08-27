# Changelog

## 0.6.6 - 2026-08-27

A swarm-health release. Under CGNAT, where a torrent runs on a handful of peers,
three separate mechanisms were removing peers we could not afford to lose or
parking them on work they were not allowed to do — torrents sat at 99% for hours
with unchoked idle peers and unclaimed blocks side by side.

### Fixed

- Peers are no longer banned for correctly answering a request we withdrew.
  A cancel is not atomic: BEP 6 obliges the peer to answer every request exactly
  once, so a block cancelled, choked or repinned away still arrives one RTT
  later. Both the piece and the reject landed in the "not outstanding" branch,
  which disconnected the peer and blacklisted its ID across every torrent — 46
  bans from `handle_piece` and 29 from `handle_reject` in five minutes, hitting
  the Fast clients hardest precisely because they are the ones obliged to
  reject. Withdrawn blocks are now remembered in a bounded per-block *count*
  (one answer per request, so arrival order stops mattering) evicted by
  generation rather than cleared wholesale. An answer matching neither set is
  wasteful, not malicious: it ends the connection at 512 blocks without banning.
- Fast-extension messages sent without the extension advertised, and frames that
  stall half-way, no longer ban the peer. 71 of 98 disconnects in one
  three-minute window were mainstream qBittorrent and Transmission builds.
  `have_all`/`have_none` now go through the normal bitfield handler — a seeder
  recorded as having nothing is a peer we can never request from — and the
  advisory messages are logged and ignored. A truncated frame is a congested
  path, so the connection still drops, but the ID is not blacklisted.
- Peer bans expire. The blacklist was a `MapSet` that only grew, so one bad
  frame excluded a peer for the whole session across every torrent: 352 IDs in
  ten minutes while eight of nine torrents could not exceed three connections.
  Bans now last 30 minutes with a cap and a background sweep, and each records
  the rule that fired.
- The dial layer no longer writes off a candidate pool a CGNAT host cannot
  refill. A failure row was cleared only by `mark_productive/3`, which asks
  whether an endpoint was *useful* rather than whether it is *reachable* — a
  leecher we keep choked never delivers bytes and so carried its failure history
  forever; registration now clears it, inbound peers included. Retention was
  also refreshed on every failure, so a row re-dialled once per 30 minutes never
  aged out and reached fail counts above 100; escalation now counts failures
  within a 10-minute streak window. Sticky blocks became last-resort under
  `min_count` pressure (productive, then soft before sticky, then v6 before v4,
  then fewest failures) instead of refusing resurrection absolutely — 1151 of
  1162 active blocks did, leaving a 50-endpoint request returning 3-8.
- Endgame now applies to pieces that were already in flight when the torrent
  crossed the threshold. A worker read the mode once at `State.download/3`, so
  exactly the pieces endgame exists for ran without redundancy: one 1 MiB piece
  held a torrent at 99.939% for over an hour with all 27 remaining blocks in
  flight to a single peer that had logged 297 request timeouts on it, while
  three unchoked peers holding the piece had nothing they were allowed to ask
  for. `:reconcile_pump` upgrades active workers level-triggered; the transition
  is idempotent and one-way and re-queues in-flight subpieces so endgame *adds*
  sources for a block rather than taking it from the peer already fetching it.
- A pin is released from an unchoked peer that delivers nothing. The staleness
  test required `choke_me`, but a choked peer holds no requests at all — the
  harmful case was the one it skipped, an unchoked peer sitting on a full
  64-request pipeline nobody else may touch. Two such peers re-requested their
  64 blocks 821 and 622 times in five minutes while two pieces with every block
  unclaimed had no peer. Zero bytes now releases the pin either way, on a longer
  threshold when unchoked (60 s, more than a block timeout) than when choked.
- A peer is no longer repinned off the piece it is fetching. "Drained" ignored
  *who* had claimed the blocks, so a peer that had claimed the rest of its piece
  made it look finished, was moved away, and the move cancelled the very
  requests that drained it — oscillating at the 2 s tick, 17 wire requests per
  block received. Draining now also requires no in-flight requests from that
  peer. Measured over seven minutes live: requests per block 17:1 → 1.1:1,
  re-request factor 5.66× → 1.08×, swarm 28 → 73 peers, 1.79 → 2.47 MB/s.
- Two endgame defects that parked torrents just short of completion: the
  drained-pin probe branched on the *torrent's* mode rather than the worker's,
  holding a pin for work that worker could never hand out, and
  `endgame_preferred_index/2` destructured the peer key backwards
  (`{_hash, peer_id}` against `Peer.make_key/2`'s `{id, hash}`), hashing the
  torrent hash and so funnelling the entire swarm onto one index.
- Outside endgame, a peer may leave a piece whose blocks are all claimed.
  `piece_has_waiting?/2` counts blocks in flight to *other* peers, which a
  normal-mode worker can never hand out — 27 of 37 peers were pinned to 4
  claimed pieces while 8 pieces with 49-64 free blocks had no peer at all.
- A piece worker whose holders have all disconnected is released. The abort
  check also required the swarm to be empty, so on any torrent with peers such a
  worker held one of the `@max_parallel_pieces` slots forever — 7 of 12 slots
  live, capping a torrent with 26 unchoked peers at 5 pieces in flight.
- A piece failing its SHA-1 check now blames the peer that supplied it. The
  worker previously just re-requested every block and could pick the same peer
  again; one torrent sat at 99.84% for hours re-downloading one index. Blocks
  now remember their source, a peer stops being asked for an index it has
  corrupted, and is dropped after `@max_hash_failures` *distinct* ruined pieces.
- Writes to a peer that has stopped reading are bounded. A TCP socket defaults
  to `send_timeout: :infinity`, so a sender blocked inside `:prim_inet.send/4`
  never returned and its mailbox only grew — one held 20863 messages. Accepted
  and dialled sockets now take a 30 s send timeout and close on it.
- The upload delivery task no longer crashes when a peer cannot take a block.
  Only `:noproc` was tolerated, so a peer shutting down mid-call produced one
  crash report per in-flight block — 333 in fifteen minutes. BEP 3 permits
  simply not answering a request, so this is now a cancellation with one debug
  line; any other exit still crashes.
- One pending pump wake per torrent. Every trigger — the 2 s reconcile tick,
  each peer handoff, every `requests_are_dealt` closure — started its own
  self-rescheduling `{:next_piece}` chain, and they accumulated: 99 → ~2600
  discovery dial cycles per minute over twelve minutes with no change in swarm
  size, until the tracker answered 403.
- A peer disconnect logs why it ended. `Peer.Endpoints` monitors a supervisor
  with `auto_shutdown: :any_significant`, which exits with a bare `:shutdown`
  whatever the child's reason was, so every disconnect read `reason=:shutdown` —
  useless for the one question worth asking, whether the peer left or we dropped
  it. A protocol error now also logs the rejected wire message, and the
  piece-bounds check logs the block alongside the torrent's geometry.
- The background DHT metadata-lookup dedup table has a permanent owner. It was
  created by whichever `Magnet.Fetcher` ran first and died with that torrent, so
  every later background task crashed with `ArgumentError` on insert; a
  supervised GenServer now owns it.

### Performance

- Dial batches overlap instead of serialising on their slowest endpoint. One
  endpoint can hold a slot for the whole connect + handshake budget (measured
  successes at 16 s, 42 s and 42 s, worst case near 55 s), and until it resolved
  the manager would start nothing new for that torrent. That hurt worst where it
  mattered most: a starved torrent with an all-IPv4 queue is capped to a
  four-endpoint probe batch, so it made four attempts per minute against a
  ~1% CGNAT success rate. Batches are now bounded by endpoints in flight (40)
  and concurrent batches (3), with in-flight endpoints excluded from selection
  so two batches cannot dial the same peer.


## 0.6.5 - 2026-08-18

### Added

- A built-in RC4 stream cipher (`Peer.MSE.RC4`), selected automatically when the
  linked libcrypto does not expose RC4. OpenSSL 3 moved RC4 into the optional
  `legacy` provider and the Windows ERTS ships no legacy module, so `:crypto`
  omits `:rc4` there — and because the whole MSE handshake is RC4-encrypted,
  including the exchange that selects a plaintext stream, such a node could not
  speak MSE at all and every peer dial failed. `config :elixir_torrent, :mse_rc4`
  accepts `:auto` (default), `:crypto`, `:pure` or `:disabled`.

### Fixed

- Tracker announces now choose their source address by asking the kernel which
  local address routes to the destination, instead of taking one from
  `Acceptor.all_global_ips/0`. Windows enforces the strong host model and refuses
  a bind whose address does not belong to the routing interface, so with a VPN,
  a second NIC or tethering every announce failed with `:eaddrnotavail`. BEP 7 is
  unchanged where a routable global address exists; an announce refused for the
  bind is retried once unbound.
- `Magnet.Fetcher.finalize_piece_attempt/1` no longer raises `FunctionClauseError`
  on a non-retryable piece attempt, which previously took down the entire magnet
  fetch instead of that one attempt. `:econnreset` and `:econnaborted` — how a
  departing peer is reported on Windows — are now treated as retryable.
- The DHT IPv4 socket logged `bind=<primary ip>` while actually being bound to
  `0.0.0.0`.

### Changed

- The test suite now runs on Windows. It previously failed before the first test
  on a `/dev/null` path, and then on `localhost` resolution: the suite forbids DNS
  on the wire, Unix answers `localhost` from `/etc/hosts`, and Windows ships that
  line commented out. Three platform assumptions in tests and three TOCTOU races
  were fixed alongside.

## 0.6.4 - 2026-08-12

### Added

- Test coverage for paths that previously only ran against a live network or a hostile peer: address classification and the NAT-PMP codec, the `Peer.Controller.State` wire state machine including BEP 16 super-seed bookkeeping, the BEP 3 choke algorithm and swarm teardown, DHT (BEP 5) degraded-mode callbacks, ut_pex (BEP 11/40) ordering, tracker announce edge cases, BEP 9 metadata fetch, STUN parsing, dial backoff sweeps, and BEP 52 v2 padding-gap reads/writes.

### Changed

- `Acceptor.compute_all_global_ips/1` is now a public arity-1 function taking the `:inet.getifaddrs()` result, so the rules deciding which addresses may be advertised to trackers, DHT and PEX can be evaluated against a supplied interface list rather than the host's own.
- `Magnet.Fetcher`'s BEP 5 retry windows (`dht_retry_delays_ms/0`, `dht_deep_retry_delay_ms/0`) are read through the existing fetcher config override instead of compile-time attributes, so the propagation waits are adjustable without changing the retry shape. Defaults unchanged.

## 0.6.3 - 2026-08-11

### Fixed

- Release pipeline: `cosign sign-blob` now writes a `--bundle` file instead of the deprecated `--output-signature`/`--output-certificate` flags, which current cosign silently ignores in favor of its new Sigstore bundle format (0.6.2's release signing failed with `create bundle file: open : no such file or directory` as a result). The bundle is named `*.tar.sigstore.json` so OpenSSF Scorecard's Signed-Releases check recognizes it. No runtime/library changes.

## 0.6.2 - 2026-08-11

### Fixed

- Release pipeline: publishing to Hex.pm is now idempotent (skips cleanly if the tag's version is already on Hex.pm instead of failing), and cosign's release-signing step retries on transient OIDC-token fetch failures instead of falling through to an interactive device-code flow that stalls CI. No runtime/library changes.

## 0.6.1 - 2026-08-11

### Changed

- Runtime pin moved to Elixir 1.20.3 + OTP 29.0.5 (ERTS 17.0.5)
- Hackney 4.7.2, H2 0.11.0, QUIC 1.8.0, WebTransport 0.4.4 (HTTP stack behind HTTPoison, used by HTTP trackers, scrape, and BEP 19 web seeds)

## 0.6.0 - 2026-08-04

### Added

- **BEP 14 (LSD):** Local Service Discovery via UDP multicast (`BT-SEARCH`)
- **BEP 19 (WebSeed):** HTTP `Range` seeding from `url-list` via `Torrent.WebSeed`
- **BEP 48:** periodic tracker scrape; skip confirmed dead-swarm announce URLs
- **BEP 52 (phases 1–2/6):** detect v1/hybrid/v2, parse peers' v2 handshake capability; accept hybrid torrents/magnets; reject pure-v2 cleanly
- **Lazy piece storage:** on-demand piece read/write/verify workers with idle terminate
- **Peer.ConnectionManager:** outbound dial orchestration with per-family throttle
- Mid-download session checkpoint (bitfield + counters every 30s)
- Magnet `x.pe` peers kept as live dial candidates after metadata fetch
- Developer quality gate: warnings-as-errors compile, Dialyzer, and all enabled Credo checks at every priority via `mix quality`

### Changed

- `Magnet.Connection` sources its BEP 3 choke/unchoke/interested wire ids from `Peer.Const` instead of a local copy
- CI publish workflow renamed to `build-and-publish`, gated to run `mix hex.publish` on semver tag pushes

### Fixed

- NAT-PMP and UPnP passive UDP receive handling now decodes the datagram payload instead of the source-address tuple
- Global 2 MiB recv-buffer ceiling now bounds every wire frame's declared length, not only the six previously-capped ids
- Per-connection stall watchdog disconnects peers that trickle a declared frame length in forever instead of completing it
- Declared bitfield/piece frame lengths capped ahead of buffering, closing a memory-amplification gap alongside the existing LTEP/BEP 52 caps
- Tracker `started` is now resent on the first announce of every session (e.g. after a cold restart), not only once per info hash ever

## 0.5.1 - 2026-07-22

### Changed

- README: single-row shields.io badges at the top for release, Hex, HexDocs, changelog, source, Web UI, and macOS downloads

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

