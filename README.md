# ElixirTorrent

BitTorrent client **engine** for Elixir/OTP — embed downloads in your own app with a small, stable public API.

## About

This is a **fully functional BitTorrent client** that actually downloads torrents — not a stub or protocol sketch. It started as a course project for **Functional Programming with Elixir** at **Sofia University**. After the course ended, development continued in spare time until it was ready to publish on Hex.

| | |
| --- | --- |
| **Hex** | [`hex.pm/packages/elixir_torrent`](https://hex.pm/packages/elixir_torrent) |
| **Docs** | [`hexdocs.pm/elixir_torrent`](https://hexdocs.pm/elixir_torrent) |
| **Changelog** | [`hexdocs.pm/elixir_torrent/changelog.html`](https://hexdocs.pm/elixir_torrent/changelog.html) |
| **Source** | [`github.com/daniboybye/ElixirTorrent`](https://github.com/daniboybye/ElixirTorrent) |

## ElixirTorrent Web (desktop app)

Need a full client, not just the library? **[ElixirTorrent Web](https://github.com/daniboybye/ElixirTorrentWebUI)**
is the official Phoenix LiveView UI for this engine, shipped as a native macOS desktop app.

- **Repository:** [github.com/daniboybye/ElixirTorrentWebUI](https://github.com/daniboybye/ElixirTorrentWebUI)
- **Download (macOS Apple Silicon):** [Release 0.1.0](https://github.com/daniboybye/ElixirTorrentWebUI/releases/tag/0.1.0)

The sections below cover the **engine API** for Elixir developers embedding BitTorrent in their own apps.

## Installation

Add `elixir_torrent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:elixir_torrent, "~> 0.3.0"}
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

## Quick start

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
| `stats/2` | Runtime stats map (`:name`, `:speed`, `:downloaded`, `:bytes_size`, …) |
| `list/0` | Info hashes for all active torrent processes |
| `list_files/1` | Per-file paths and download progress |
| `stop_and_serialize/1` | Graceful stop + persist session |
| `stop_all_and_serialize/0` | Graceful stop + persist for every torrent |
| `remove/2` | Stop and drop from session; optional `delete_data: true` |
| `get/2` | Low-level field access (prefer `stats/2`) |
| `version/0` | Client peer ID prefix (`ET0-3-0`, BEP 20) |

## Supported BEPs

| BEP | Topic |
| --- | --- |
| [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) | BitTorrent protocol |
| [BEP 4](https://www.bittorrent.org/beps/bep_0004.html) | Known number allocations |
| [BEP 5](https://www.bittorrent.org/beps/bep_0005.html) | Mainline DHT |
| [BEP 6](https://www.bittorrent.org/beps/bep_0006.html) | Fast extension |
| [BEP 7](https://www.bittorrent.org/beps/bep_0007.html) | IPv6 tracker extension |
| [BEP 9](https://www.bittorrent.org/beps/bep_0009.html) | Extension for peers to send metadata files (ut_metadata) |
| [BEP 10](https://www.bittorrent.org/beps/bep_0010.html) | Extension protocol (LTEP) |
| [BEP 11](https://www.bittorrent.org/beps/bep_0011.html) | Peer exchange (ut_pex) |
| [BEP 12](https://www.bittorrent.org/beps/bep_0012.html) | Multitracker metadata |
| [BEP 15](https://www.bittorrent.org/beps/bep_0015.html) | UDP tracker protocol |
| [BEP 20](https://www.bittorrent.org/beps/bep_0020.html) | Peer ID conventions |
| [BEP 23](https://www.bittorrent.org/beps/bep_0023.html) | Compact peer lists |
| [BEP 24](https://www.bittorrent.org/beps/bep_0024.html) | Tracker returns external IP |
| [BEP 29](https://www.bittorrent.org/beps/bep_0029.html) | Micro Transport Protocol (uTP) |
| [BEP 31](https://www.bittorrent.org/beps/bep_0031.html) | Failure retry extension |
| [BEP 55](https://www.bittorrent.org/beps/bep_0055.html) | Hole punching (ut_holepunch) |

## CLI (escript)

The package builds an escript for ad-hoc testing:

```bash
mix escript.build
./elixir_torrent
# then type: download /path/to/file.torrent
```

For production use, call the API from your OTP application instead.
