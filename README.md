## ElixirTorrent

BitTorrent client **engine** written in Elixir.

[Changelog](https://hexdocs.pm/elixir_torrent/changelog.html)

## ElixirTorrent Web (desktop app)

Need a full client, not just the library? **[ElixirTorrent Web](https://github.com/daniboybye/ElixirTorrentWebUI)**
is the official Phoenix LiveView UI for this engine, shipped as a native macOS desktop app.

- **Repository:** [github.com/daniboybye/ElixirTorrentWebUI](https://github.com/daniboybye/ElixirTorrentWebUI)
- **Download (macOS Apple Silicon):** [Release 0.1.0](https://github.com/daniboybye/ElixirTorrentWebUI/releases/tag/0.1.0)

The sections below cover the **engine API** for Elixir developers embedding BitTorrent in their own apps.

## Supported BEPs

BEP 03 - The BitTorrent Protocol Specification  
BEP 04 - Known Number Allocations  
BEP 06 - Fast Extension  
BEP 07 - IPv6 Tracker Extension  
BEP 12 - Multitracker Metadata Extension  
BEP 15 - UDP Tracker Protocol  
BEP 20 - Peer ID Conventions  
BEP 23 - Tracker Returns Compact Peer Lists  
BEP 24 - Tracker Returns External IP  
BEP 31 - Failure Retry Extension

```elixir
def deps do
  [
    {:elixir_torrent, "~> 0.1.2"}
  ]
end
```