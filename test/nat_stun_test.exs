defmodule NAT.StunTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias NAT.Stun

  @magic_cookie 0x2112A442

  describe "encode_request/1" do
    test "builds a 20-byte Binding Request with magic cookie and txid" do
      txid = :crypto.strong_rand_bytes(12)
      req = Stun.encode_request(txid)

      assert byte_size(req) == 20
      assert <<0x0001::16, 0::16, @magic_cookie::32, ^txid::binary-size(12)>> = req
    end
  end

  describe "decode_reflexive/2" do
    test "decodes an XOR-MAPPED-ADDRESS response" do
      txid = :crypto.strong_rand_bytes(12)
      resp = success_response(txid, xor_mapped_attr({203, 0, 113, 5}, 51_234))

      assert {:ok, {{203, 0, 113, 5}, 51_234}} = Stun.decode_reflexive(resp, txid)
    end

    test "decodes a legacy MAPPED-ADDRESS response" do
      txid = :crypto.strong_rand_bytes(12)
      resp = success_response(txid, mapped_attr({198, 51, 100, 9}, 6881))

      assert {:ok, {{198, 51, 100, 9}, 6881}} = Stun.decode_reflexive(resp, txid)
    end

    test "prefers XOR-MAPPED-ADDRESS over MAPPED-ADDRESS when both present" do
      txid = :crypto.strong_rand_bytes(12)

      attrs =
        mapped_attr({10, 0, 0, 1}, 1111) <> xor_mapped_attr({203, 0, 113, 5}, 51_234)

      resp = success_response(txid, attrs)

      assert {:ok, {{203, 0, 113, 5}, 51_234}} = Stun.decode_reflexive(resp, txid)
    end

    test "rejects a response whose transaction id does not match the request" do
      resp = success_response(:crypto.strong_rand_bytes(12), xor_mapped_attr({1, 2, 3, 4}, 5))

      assert {:error, :bad_response} = Stun.decode_reflexive(resp, :crypto.strong_rand_bytes(12))
    end

    test "reports missing mapped address" do
      txid = :crypto.strong_rand_bytes(12)
      # A SOFTWARE attribute (0x8022) we don't parse, nothing addressable.
      resp = success_response(txid, <<0x8022::16, 4::16, "test">>)

      assert {:error, :no_mapped_address} = Stun.decode_reflexive(resp, txid)
    end
  end

  describe "classify/1" do
    test "identical reflexive ports across servers => endpoint_independent (cone)" do
      assert Stun.classify([{{203, 0, 113, 5}, 51_234}, {{203, 0, 113, 5}, 51_234}]) ==
               :endpoint_independent
    end

    test "differing reflexive ports => endpoint_dependent (symmetric)" do
      assert Stun.classify([{{203, 0, 113, 5}, 51_234}, {{203, 0, 113, 5}, 61_000}]) ==
               :endpoint_dependent
    end

    test "fewer than two observations => unknown" do
      assert Stun.classify([{{203, 0, 113, 5}, 51_234}]) == :unknown
      assert Stun.classify([]) == :unknown
    end
  end

  describe "mapping/0 cache" do
    test "defaults to :unknown and round-trips through put_mapping/1" do
      Stun.put_mapping(:unknown)
      assert Stun.mapping() == :unknown

      Stun.put_mapping(:endpoint_independent)
      assert Stun.mapping() == :endpoint_independent

      Stun.put_mapping(:endpoint_dependent)
      assert Stun.mapping() == :endpoint_dependent
    after
      Stun.put_mapping(:unknown)
    end
  end

  defp success_response(txid, attrs) do
    <<0x0101::16, byte_size(attrs)::16, @magic_cookie::32, txid::binary-size(12), attrs::binary>>
  end

  defp xor_mapped_attr({a, b, c, d}, port) do
    <<addr::32>> = <<a, b, c, d>>
    x_port = bxor(port, 0x2112)
    x_addr = bxor(addr, @magic_cookie)
    value = <<0, 0x01, x_port::16, x_addr::32>>
    <<0x0020::16, byte_size(value)::16, value::binary>>
  end

  defp mapped_attr({a, b, c, d}, port) do
    value = <<0, 0x01, port::16, a, b, c, d>>
    <<0x0001::16, byte_size(value)::16, value::binary>>
  end
end
