defmodule DHT.NodeIdTest do
  use ExUnit.Case, async: false

  alias DHT.{BEP42, NodeId}

  setup do
    tmp = Path.join(System.tmp_dir!(), "et_node_id_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    previous_cwd = File.cwd!()
    File.cd!(tmp)

    id_file = NodeId.path()
    File.rm_rf(Path.dirname(id_file))

    on_exit(fn ->
      File.cd!(previous_cwd)
      File.rm_rf(tmp)
    end)

    :ok
  end

  test "path/0 resolves under the current working directory" do
    expected = Path.join([File.cwd!(), ".elixir_torrent", "dht_node_id.bin"])
    assert NodeId.path() == expected
  end

  test "get/0 creates and persists a 20-byte id when the file is missing" do
    refute File.exists?(NodeId.path())

    id = NodeId.get()

    assert byte_size(id) == 20
    assert File.read(NodeId.path()) == {:ok, id}
    assert NodeId.get() == id
  end

  test "get/0 reuses a persisted BEP-42-valid id when primary IP is known" do
    ip = node_primary_ip()

    if ip == nil do
      assert true
    else
      middle = :crypto.strong_rand_bytes(16)
      rand_byte = 73
      valid_id = BEP42.generate(ip, rand_byte, middle)
      File.mkdir_p!(Path.dirname(NodeId.path()))
      :ok = File.write(NodeId.path(), valid_id)

      assert NodeId.get() == valid_id
    end
  end

  test "get/0 regenerates invalid BEP-42 prefix while preserving middle and rand byte" do
    ip = node_primary_ip()

    if ip == nil do
      assert true
    else
      middle = :crypto.strong_rand_bytes(16)
      rand_byte = 91
      invalid_id = <<0xFF, 0xFF, 0xFF, middle::binary-size(16), rand_byte::8>>

      refute BEP42.valid?(invalid_id, ip)

      File.mkdir_p!(Path.dirname(NodeId.path()))
      :ok = File.write(NodeId.path(), invalid_id)

      regenerated = NodeId.get()

      assert byte_size(regenerated) == 20
      assert BEP42.valid?(regenerated, ip)
      assert <<_::binary-size(3), ^middle::binary-size(16), ^rand_byte::8>> = regenerated
      assert regenerated != invalid_id
      assert File.read(NodeId.path()) == {:ok, regenerated}
    end
  end

  test "get/0 returns persisted id unchanged when no global primary IP is available" do
    ip = node_primary_ip()

    if ip != nil do
      assert true
    else
      stored = :crypto.strong_rand_bytes(20)
      File.mkdir_p!(Path.dirname(NodeId.path()))
      :ok = File.write(NodeId.path(), stored)

      assert NodeId.get() == stored
    end
  end

  defp node_primary_ip do
    ips = Acceptor.primary_ips()

    cond do
      is_tuple(ips.inet6) -> ips.inet6
      is_tuple(ips.inet) -> ips.inet
      true -> nil
    end
  end
end
