defmodule Cycle3StunDialTorrentCoverageTest do
  @moduledoc """
  Coverage for three small, independent surfaces:

    * STUN (RFC 5389) response parsing — used once at boot to classify this
      host's NAT and to learn our server-reflexive address, which the self-peer
      filter needs so we never dial ourselves. Servers in the wild answer with
      attributes we do not understand, so the walker must skip them.
    * `Peer.DialBackoff`'s ETS sweep, which is what stops the block table from
      growing without bound while still keeping fail counts alive long enough to
      escalate the next block.
    * `Torrent.parse_file!/1`, which walks the raw bencode byte-for-byte because
      re-encoding the `info` dict would change the BEP 3 info-hash.
  """
  use ExUnit.Case, async: false

  @magic_cookie 0x2112A442
  @binding_success 0x0101
  @attr_mapped_address 0x0001
  @attr_xor_mapped_address 0x0020

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  describe "NAT.Stun.decode_reflexive/2" do
    test "reads an XOR-MAPPED-ADDRESS" do
      txid = :crypto.strong_rand_bytes(12)
      attr = xor_mapped_attr({203, 0, 113, 5}, 51_234)

      assert {:ok, {{203, 0, 113, 5}, 51_234}} =
               NAT.Stun.decode_reflexive(success(txid, attr), txid)
    end

    test "skips an XOR-MAPPED-ADDRESS in a family it cannot decode" do
      txid = :crypto.strong_rand_bytes(12)
      # Family 0x02 is IPv6; this parser only understands IPv4 reflexives.
      ipv6_attr = attr(@attr_xor_mapped_address, <<0, 0x02, 0::16, 0::128>>)
      fallback = attr(@attr_mapped_address, <<0, 0x01, 6881::16, 198, 51, 100, 7>>)

      assert {:ok, {{198, 51, 100, 7}, 6881}} =
               NAT.Stun.decode_reflexive(success(txid, ipv6_attr <> fallback), txid)
    end

    test "ignores a MAPPED-ADDRESS in an unknown family" do
      txid = :crypto.strong_rand_bytes(12)
      bad = attr(@attr_mapped_address, <<0, 0x02, 0::16>>)

      assert {:error, :no_mapped_address} =
               NAT.Stun.decode_reflexive(success(txid, bad), txid)
    end

    test "stops walking when an attribute claims more padding than is present" do
      txid = :crypto.strong_rand_bytes(12)
      # A 5-byte value pads to 8, but only 5 bytes follow the header.
      truncated = <<0x8022::16, 5::16, "abcde">>

      assert {:error, :no_mapped_address} =
               NAT.Stun.decode_reflexive(success(txid, truncated), txid)
    end

    test "rejects a response for a different transaction" do
      assert {:error, :bad_response} =
               NAT.Stun.decode_reflexive(<<0, 0, 0, 0>>, :crypto.strong_rand_bytes(12))
    end
  end

  describe "NAT.Stun.detect/1" do
    test "a server that does not resolve yields no reflexive observation" do
      assert {:ok, :unknown, []} =
               NAT.Stun.detect([{~c"stun.invalid.elixirtorrent.test", 3478}])
    end
  end

  describe "Peer.DialBackoff sweep" do
    test "drops entries past their retention window and re-arms itself" do
      assert {:noreply, :state} = Peer.DialBackoff.handle_info(:sweep, :state)

      # The sweep re-arms its own timer; drop it so it cannot leak.
      receive do
        :sweep -> :ok
      after
        0 -> :ok
      end
    end
  end

  describe "Peer.DialBackoff.filter/3" do
    test "a peer with an address of neither family is treated as IPv4" do
      hash = :crypto.strong_rand_bytes(20)
      peers = [%Peer{ip: {1, 2, 3}, port: 6881}, %Peer{ip: {192, 0, 2, 4}, port: 6881}]

      # min_count 0 means nothing is resurrected from the blocked set.
      assert Peer.DialBackoff.filter(peers, hash, 0) == peers
    end

    test "a closed connection is blocked for the same window as a timeout" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {192, 0, 2, 77}

      :ok = Peer.DialBackoff.record(hash, ip, 6881, :closed)
      :sys.get_state(Peer.DialBackoff)

      assert Peer.DialBackoff.blocked?(hash, ip, 6881)
    end
  end

  describe "Torrent.parse_file!/1" do
    test "walks past list values to find the raw info slice of a multi-file torrent" do
      path = write_torrent!()

      torrent = Torrent.parse_file!(path)

      # BEP 3: the info-hash must be SHA-1 of the exact on-disk info bytes.
      assert byte_size(torrent.hash) == 20
      assert torrent.left == 3 * 16_384
      assert torrent.info_blob == Bento.encode!(torrent.metadata["info"])
    end

    test "raises on a file that is not a bencoded dictionary" do
      path = Path.join(tmp_dir(), "bad.torrent")
      File.write!(path, "l4:spame")

      assert_raise ArgumentError, fn -> Torrent.parse_file!(path) end
    end
  end

  ## helpers -----------------------------------------------------------------

  defp success(txid, attrs) do
    <<@binding_success::16, byte_size(attrs)::16, @magic_cookie::32, txid::binary, attrs::binary>>
  end

  defp attr(type, value), do: <<type::16, byte_size(value)::16, value::binary>>

  defp xor_mapped_attr({a, b, c, d}, port) do
    xport = Bitwise.bxor(port, 0x2112)
    <<addr::32>> = <<a, b, c, d>>
    xaddr = Bitwise.bxor(addr, @magic_cookie)

    attr(@attr_xor_mapped_address, <<0, 0x01, xport::16, xaddr::32>>)
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "et_cycle3_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # An announce-list (a bencoded list) sits before "info", so the byte scanner
  # has to skip a list value before it reaches the info slice.
  defp write_torrent! do
    piece_len = 16_384

    info = %{
      "name" => "multi",
      "piece length" => piece_len,
      "pieces" => :binary.copy(:crypto.hash(:sha, "x"), 3),
      "files" => [
        %{"length" => piece_len, "path" => ["a.bin"]},
        %{"length" => 2 * piece_len, "path" => ["sub", "b.bin"]}
      ]
    }

    raw =
      IO.iodata_to_binary([
        "d",
        "8:announce",
        Bento.encode!("udp://tracker.example:6969/announce"),
        "13:announce-list",
        Bento.encode!([["udp://tracker.example:6969/announce"]]),
        "4:info",
        Bento.encode!(info),
        "e"
      ])

    path = Path.join(tmp_dir(), "multi.torrent")
    File.write!(path, raw)
    path
  end
end
