import Config

# The suite boots the real OTP application, so every background subsystem that
# talks to the network starts with it. Nothing here changes protocol behaviour —
# each switch removes a path whose only effect is to send packets off this
# machine. Tests that need one of these paths drive it directly against a
# loopback fixture (see `.claude/TESTING.md` § Network isolation).

# BEP 5 DHT stays enabled — a large part of the suite exercises it — but it
# starts with no public bootstrap routers (those cost a DNS lookup plus UDP to
# router.bittorrent.com & co) and never touches the persisted routing table,
# whose contacts are real internet nodes that the boot bootstrap lookup would
# query immediately. Not saving it either keeps a test run from overwriting a
# developer's warm table with the empty one the suite runs on.
config :elixir_torrent, :dht,
  enabled: true,
  bootstrap_routers: [],
  routing_store: false

# BEP 14 Local Service Discovery multicasts this host's info-hashes to
# 239.192.152.143 / ff15::efc0:988f on every LAN interface.
config :elixir_torrent, :lsd, enabled: false

# NAT-PMP talks to the LAN gateway, UPnP SSDP-multicasts, and STUN NAT-type
# detection queries public servers.
config :elixir_torrent, :nat, enabled: false

# Peers reach the dial path from decoded tracker/DHT/PEX fixtures that carry
# real addresses; without this, a fixture peer becomes a real connection attempt
# to a stranger. `:this_host` still allows everything the loopback fixtures dial
# (127.0.0.1, ::1, and this machine's own interface addresses) — those packets
# never reach the wire — and refuses everything else at the connect call itself.
config :elixir_torrent, :network, dial_scope: :this_host
