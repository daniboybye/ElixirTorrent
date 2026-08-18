# No test may put a DNS query on the wire. `:file` lookup answers from
# /etc/hosts only: `localhost` still resolves to 127.0.0.1/::1, and every other
# name — the `.invalid` fixtures, the BEP 5 bootstrap routers, a tracker
# hostname decoded out of a fixture — fails `:nxdomain` immediately instead of
# after a round-trip to the resolver. The subsystems that would otherwise open
# sockets on their own (DHT bootstrap, LSD multicast, NAT/STUN, outbound dials)
# are switched off in `config/test.exs`.
:ok = :inet_db.set_lookup([:file])

# `set_lookup/1` only binds `:inet`. `:inet_res` is a separate resolver that
# some libraries (hackney's happy-eyeballs path) call directly, and it lazily
# loads /etc/resolv.conf on first use — which is how AAAA queries for fixture
# tracker hostnames were still reaching the LAN router. Pointing it at an empty
# file leaves it with no nameserver to ask, so it answers :nxdomain instead.
#
# A real empty file, not `/dev/null`: that path does not exist on Windows, where
# `set_resolv_conf/1` then returns `:error` and this match brought the whole
# suite down before the first test ran.
empty_resolv_conf = Path.join(System.tmp_dir!(), "elixir_torrent_empty_resolv.conf")
File.write!(empty_resolv_conf, "")
:ok = :inet_db.set_resolv_conf(String.to_charlist(empty_resolv_conf))

# `[:file]` lookup answers from the platform's hosts file, and that file is not
# the same everywhere. On Unix `/etc/hosts` ships the `localhost` lines. On
# Windows the corresponding lines in
# `%SystemRoot%\system32\drivers\etc\hosts` are *commented out* by default:
# the DNS Client service answers `localhost` internally, from the resolver we
# have just disconnected. So `localhost` came back `:nxdomain` there while it
# resolved on macOS.
#
# Seed the two loopback names into `inet_db`'s own host table instead of
# relying on the file. `add_host/2` entries are consulted by the `:file` lookup
# method ahead of the file-loaded ones, so this is platform-independent, and it
# does not widen the isolation by one name: everything else still fails
# `:nxdomain` with no packet sent.
:ok = :inet_db.add_host({127, 0, 0, 1}, [~c"localhost"])
:ok = :inet_db.add_host({0, 0, 0, 0, 0, 0, 0, 1}, [~c"localhost"])

:ok = :logger.update_handler_config(:default, :level, :warning)
ExUnit.start(capture_log: true)
