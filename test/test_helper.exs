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
:ok = :inet_db.set_resolv_conf(~c"/dev/null")

:ok = :logger.update_handler_config(:default, :level, :warning)
ExUnit.start(capture_log: true)
