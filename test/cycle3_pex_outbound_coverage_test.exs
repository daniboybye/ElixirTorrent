defmodule Cycle3PexOutboundCoverageTest do
  @moduledoc """
  Coverage for how a ut_pex (BEP 11) message orders the endpoints it carries.

  BEP 40 defines a client-relative priority so two peers that exchange the same
  swarm view converge on the same ordering; when we have no client reference for
  a family (no known local address of that family, and the remote never told us
  our address via the BEP 10 `yourip` field) the ordering falls back to a plain
  sort so the output stays deterministic rather than arbitrary.
  """
  use ExUnit.Case, async: false

  alias Peer.Controller.State
  alias Peer.LTEP.{Handshake, Session}
  alias Peer.UtPex.{Entry, Outbound}

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "ordering without a BEP 40 client reference" do
    test "entries fall back to endpoint order, IPv4 before IPv6" do
      entries = [
        Entry.normalize({{0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}, 6881}),
        Entry.normalize({{198, 51, 100, 9}, 6881}),
        Entry.normalize({{198, 51, 100, 2}, 6881})
      ]

      assert [a, b, c] = Outbound.order_entries(entries, %{inet: nil, inet6: nil})

      assert Entry.endpoint(a) == {{198, 51, 100, 2}, 6881}
      assert Entry.endpoint(b) == {{198, 51, 100, 9}, 6881}
      assert Entry.endpoint(c) == {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}, 6881}
    end

    test "dropped endpoints fall back to plain sort order" do
      endpoints = [
        {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}, 6881},
        {{198, 51, 100, 9}, 6881},
        {{198, 51, 100, 2}, 6881}
      ]

      assert [
               {{198, 51, 100, 2}, 6881},
               {{198, 51, 100, 9}, 6881},
               {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}, 6881}
             ] = Outbound.order_endpoints(endpoints, %{inet: nil, inet6: nil})
    end
  end

  describe "client reference from the BEP 10 handshake" do
    test "an IPv4 yourip becomes the IPv4 client reference" do
      refs = Outbound.client_refs(state_with_yourip(<<8, 8, 4, 4>>))

      assert {{8, 8, 4, 4}, _port} = refs.inet
    end

    test "an IPv6 yourip becomes the IPv6 client reference" do
      v6 = <<0x2606::16, 0x4700::16, 0::64, 0::16, 7::16>>
      refs = Outbound.client_refs(state_with_yourip(v6))

      assert {{0x2606, 0x4700, 0, 0, 0, 0, 0, 7}, _port} = refs.inet6
    end

    test "a non-global yourip is ignored" do
      # A peer behind the same NAT can report our RFC 1918 address; that is not
      # a usable reference for anyone else in the swarm.
      refs = Outbound.client_refs(state_with_yourip(<<10, 1, 2, 3>>))

      assert refs == Outbound.client_refs(nil)
    end

    test "a connection with no extended handshake has no reference of its own" do
      assert Outbound.client_refs(base_state(nil)) == Outbound.client_refs(nil)
    end
  end

  ## helpers -----------------------------------------------------------------

  defp state_with_yourip(yourip) do
    ltep =
      Session.new([])
      |> Session.apply_peer_handshake(Handshake.from_map(%{"yourip" => yourip}))

    base_state(ltep)
  end

  defp base_state(ltep) do
    %State{
      hash: :crypto.strong_rand_bytes(20),
      id: Peer.id(),
      pieces_count: 1,
      fast_extension: nil,
      status: nil,
      socket: nil,
      ltep: ltep
    }
  end
end
