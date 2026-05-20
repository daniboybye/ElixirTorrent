defmodule Bep9MetadataHardeningTest do
  use ExUnit.Case, async: false

  alias Magnet.{Connection, UtMetadata}
  alias Peer.Controller.State
  alias Peer.LTEP.{Handshake, Session}

  @block_size 16_384
  @timeout 5_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    :ok
  end

  test "data larger than one BEP 9 piece is rejected" do
    payload =
      UtMetadata.encode_data(0, @block_size + 1, :binary.copy(<<0xAA>>, @block_size + 1))

    assert {:error, :piece_too_large} = UtMetadata.decode_message(payload)
  end

  test "one peer cannot make metadata serving process an unbounded request flood" do
    info_blob = info_blob("rate-limit")
    hash = :crypto.hash(:sha, info_blob)
    model = start_model(hash, info_blob)
    id = :crypto.strong_rand_bytes(20)
    key = Peer.make_key(hash, id)
    {:ok, capture} = Bep9MetadataHardeningTest.SenderCapture.start_link(key, self())

    on_exit(fn ->
      stop_quietly(capture)
      stop_quietly(model)
    end)

    state = metadata_state(hash, id)
    request = UtMetadata.encode_request(999)
    limit = State.ut_metadata_request_limit()

    state =
      Enum.reduce(1..(limit + 5), state, fn _, acc ->
        State.handle_extended(acc, UtMetadata.Extension.local_id(), request)
      end)

    assert state.ut_metadata_requests.count == limit

    for _ <- 1..limit do
      assert_receive {:metadata_wire, wire}, @timeout
      assert {:ok, {:reject, piece: 999}} = decode_extended(wire)
    end

    refute_receive {:metadata_wire, _wire}, 50
  end

  test "multi-piece request and serve path assembles raw metadata and verifies SHA-1" do
    info_blob = info_blob(:binary.copy("m", 2 * @block_size + 500))
    hash = :crypto.hash(:sha, info_blob)
    model = start_model(hash, info_blob)
    piece_count = UtMetadata.piece_count(byte_size(info_blob))
    {conn, server, listen} = connection_pair(byte_size(info_blob))
    test_pid = self()

    task =
      start_socket_task(server, fn socket ->
        Enum.each(1..piece_count, fn _ ->
          {:request, piece} = recv_metadata_request(socket)
          send(test_pid, {:served_piece, piece})
          send_served_piece(socket, hash, piece)
        end)
      end)

    on_exit(fn ->
      Connection.close(conn)
      :gen_tcp.close(listen)
      stop_quietly(model)
    end)

    assert {:ok, ^info_blob} = Magnet.Fetcher.download_pieces([conn], hash)
    assert {:ok, decoded, ^info_blob} = UtMetadata.decode_and_verify_info(info_blob, hash)
    assert decoded["name"] == :binary.copy("m", 2 * @block_size + 500)

    served =
      for _ <- 1..piece_count do
        assert_receive {:served_piece, piece}, @timeout
        piece
      end

    assert Enum.sort(served) == Enum.to_list(0..(piece_count - 1))
    assert :ok = Task.await(task, @timeout)
  end

  test "unavailable metadata piece follows the request to reject wire path" do
    info_blob = info_blob("reject")
    hash = :crypto.hash(:sha, info_blob)
    model = start_model(hash, info_blob)
    {conn, server, listen} = connection_pair(byte_size(info_blob))

    task =
      start_socket_task(server, fn socket ->
        {:request, 99} = recv_metadata_request(socket)
        send_served_piece(socket, hash, 99)
      end)

    on_exit(fn ->
      Connection.close(conn)
      :gen_tcp.close(listen)
      stop_quietly(model)
    end)

    assert {:reject, 99} = Connection.request_piece(conn, 99)
    assert :ok = Task.await(task, @timeout)
  end

  test "invalid-size response falls back to a different peer" do
    info_blob = info_blob("fallback")
    hash = :crypto.hash(:sha, info_blob)
    total_size = byte_size(info_blob)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    peers =
      Enum.map(1..2, fn _ ->
        {conn, server, listen} = connection_pair(total_size)

        task =
          start_socket_task(server, fn socket ->
            {:request, 0} = recv_metadata_request(socket)

            attempt =
              Agent.get_and_update(attempts, fn count ->
                {count + 1, count + 1}
              end)

            if attempt == 1 do
              mismatched = info_blob <> <<0>>
              send_data(socket, 0, total_size + 1, mismatched)
            else
              send_data(socket, 0, total_size, info_blob)
            end
          end)

        {conn, listen, task}
      end)

    on_exit(fn ->
      Enum.each(peers, fn {conn, listen, _task} ->
        Connection.close(conn)
        :gen_tcp.close(listen)
      end)

      stop_quietly(attempts)
    end)

    connections = Enum.map(peers, &elem(&1, 0))

    assert {:ok, ^info_blob} = Magnet.Fetcher.download_pieces(connections, hash)
    assert Agent.get(attempts, & &1) == 2

    Enum.each(peers, fn {_conn, _listen, task} ->
      assert :ok = Task.await(task, @timeout)
    end)
  end

  defp metadata_state(hash, id) do
    ltep =
      Session.new([UtMetadata.Extension])
      |> Session.apply_peer_handshake(%Handshake{m: %{"ut_metadata" => 7}})

    %State{
      hash: hash,
      id: id,
      fast_extension: nil,
      status: :seed,
      pieces_count: 1,
      socket: nil,
      ltep: ltep
    }
  end

  defp start_model(hash, info_blob) do
    info = Bento.decode!(info_blob)

    torrent = %Torrent{
      hash: hash,
      metadata: %{"info" => info},
      info_blob: info_blob,
      left: 0,
      last_index: 0,
      last_piece_length: 1,
      bitfield: <<0x80>>
    }

    {:ok, pid} = Torrent.Model.start_link(torrent)
    pid
  end

  defp info_blob(name) do
    Bento.encode!(%{
      "length" => 1,
      "name" => name,
      "piece length" => @block_size,
      "pieces" => :crypto.hash(:sha, <<0>>)
    })
  end

  defp connection_pair(metadata_size) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw])
    {:ok, server} = :gen_tcp.accept(listen, @timeout)

    ltep =
      Session.new([UtMetadata.Extension])
      |> Session.apply_peer_handshake(%Handshake{
        m: %{"ut_metadata" => 7},
        metadata_size: metadata_size
      })

    conn = %Connection{
      socket: client,
      ltep: ltep,
      metadata_size: metadata_size,
      transport: :tcp,
      unchoked?: true,
      unchoke_since: System.monotonic_time(:millisecond)
    }

    {conn, server, listen}
  end

  defp start_socket_task(server, fun) do
    task =
      Task.async(fn ->
        receive do
          {:socket, socket} -> fun.(socket)
        end
      end)

    :ok = :gen_tcp.controlling_process(server, task.pid)
    send(task.pid, {:socket, server})
    task
  end

  defp recv_metadata_request(socket) do
    assert {:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, @timeout)
    assert {:ok, <<20, 7, payload::binary>>} = :gen_tcp.recv(socket, length, @timeout)
    assert {:ok, {:request, [piece: piece]}} = UtMetadata.decode_message(payload)
    {:request, piece}
  end

  defp send_served_piece(socket, hash, piece) do
    case UtMetadata.serve_piece(hash, piece) do
      {:ok, data, total_size} -> send_data(socket, piece, total_size, data)
      :reject -> send_payload(socket, UtMetadata.encode_reject(piece))
    end
  end

  defp send_data(socket, piece, total_size, data) do
    send_payload(socket, UtMetadata.encode_data(piece, total_size, data))
  end

  defp send_payload(socket, payload) do
    :gen_tcp.send(
      socket,
      Peer.LTEP.extended_message_wire(UtMetadata.Extension.local_id(), payload)
    )
  end

  defp decode_extended(<<_length::32, 20, 7, payload::binary>>) do
    UtMetadata.decode_message(payload)
  end

  defp stop_quietly(pid) do
    if is_pid(pid), do: TestSupport.Sync.safe_stop(pid, 500)
  end
end

defmodule Bep9MetadataHardeningTest.SenderCapture do
  @moduledoc false
  use GenServer

  @spec start_link(Peer.key(), pid()) :: GenServer.on_start()
  def start_link(key, test_pid) do
    GenServer.start_link(__MODULE__, test_pid,
      name: {:via, Registry, {Registry, {key, Peer.Sender}}}
    )
  end

  @impl GenServer
  def init(test_pid), do: {:ok, test_pid}

  @impl GenServer
  def handle_call({:socket_send_raw, wire}, _from, test_pid) do
    send(test_pid, {:metadata_wire, wire})
    {:reply, :ok, test_pid}
  end
end
