defmodule Cycle2PureProtocolCoverageBatch2Test do
  use ExUnit.Case, async: false

  alias DHT.KRPC
  alias Peer.{Endpoints, Holepunch, MSE, Transport}
  alias Peer.LTEP
  alias Peer.LTEP.Session
  alias Peer.MSE.Handshake
  alias PeerWireTest.ControllerCapture
  alias Tracker.UDP

  @hash <<0xCC, 0::152>>
  @timeout 2_000
  @transaction_id <<0x11, 0x22, 0x33, 0x44>>
  @other_transaction_id <<0xAA, 0xBB, 0xCC, 0xDD>>
  @connection_id <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08>>

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    Process.flag(:trap_exit, true)

    previous_cwd = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "et_cycle2_batch2_#{System.unique_integer([:positive])}")
    download_dir = Path.join(tmp, "downloads")
    File.mkdir_p!(download_dir)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(previous_cwd)
      File.rm_rf(tmp)
    end)

    %{download_dir: download_dir}
  end

  describe "DHT.KRPC remaining decode branches" do
    test "fetch_type/1 rejects missing or multi-byte y keys" do
      assert {:error, :malformed} =
               KRPC.decode(Bento.encode!(%{"t" => "x", "a" => %{"id" => @hash}}))

      assert {:error, :malformed} =
               KRPC.decode(Bento.encode!(%{"t" => "x", "y" => "qq", "a" => %{"id" => @hash}}))
    end

    test "fetch_map/2 rejects non-map response bodies" do
      bad_response = Bento.encode!(%{"t" => "r", "y" => "r", "r" => "not-a-map"})
      assert {:error, :malformed} = KRPC.decode(bad_response)
    end

    test "decode/1 maps non-error with-clause failures to malformed" do
      assert {:error, :malformed} = KRPC.decode(Bento.encode!(%{"t" => 123, "y" => "q"}))
    end

    test "response_peers/1 drops compact blobs whose size matches neither v4 nor v6 stride" do
      assert [] = KRPC.response_peers(%{values: <<1, 2, 3, 4, 5>>})
    end
  end

  describe "Tracker.UDP classify_response ignore branches" do
    test "connect and scrape transaction mismatches become :ignore" do
      connect_body = <<0::32, @other_transaction_id::binary, @connection_id::binary>>

      assert :ignore =
               UDP.classify_response(connect_body, @transaction_id, expected: :connect)

      scrape_body =
        <<2::32, @other_transaction_id::binary, 1::32, 2::32, 3::32, 4::32, 5::32, 6::32>>

      assert :ignore =
               UDP.classify_response(scrape_body, @transaction_id,
                 expected: :scrape,
                 hash_count: 1
               )
    end

    test "classify_scrape_response surfaces atom errors from decode_scrape_response/3" do
      assert {:error, :invalid_packet} =
               UDP.classify_response(
                 <<2::32, @transaction_id::binary>>,
                 @transaction_id,
                 expected: :scrape,
                 hash_count: 1
               )
    end
  end

  describe "Peer.MSE.Handshake loopback branches" do
    test "initiator honours plaintext crypto_select from the responder" do
      info_hash = :crypto.strong_rand_bytes(20)
      ia = "\x13BitTorrent protocol" <> :crypto.strong_rand_bytes(48)

      {client, client_result, server_result} =
        run_mse_initiator_with_custom_select(info_hash, ia, MSE.crypto_plaintext())

      assert {:ok, %{mode: :plaintext}} = client_result
      assert {:ok, _} = server_result
      :gen_tcp.close(client)
    end

    test "initiator rejects unknown crypto_select values" do
      info_hash = :crypto.strong_rand_bytes(20)
      ia = "short-ia-payload"

      {client, client_result, _server_result} =
        run_mse_initiator_with_custom_select(info_hash, ia, 0x0000_0004)

      assert {:error, {:mse_bad_select, 4}} = client_result
      :gen_tcp.close(client)
    end

    test "respond/3 propagates transport recv errors during the req1 scan" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      parent = self()

      accept =
        spawn(fn ->
          {:ok, sock} = :gen_tcp.accept(listen, @timeout)
          _prefix = :gen_tcp.recv(sock, 1, @timeout)
          :gen_tcp.close(sock)
          :gen_tcp.close(listen)
          send(parent, :responder_closed)
        end)

      {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)

      result =
        Handshake.respond(client, Handshake.resolver([:crypto.strong_rand_bytes(20)]), 200)

      assert match?({:error, _}, result)
      :gen_tcp.close(client)
      assert_receive :responder_closed, @timeout
      Process.exit(accept, :kill)
    end

    test "initiator read_select consumes a non-zero PadD from the peer" do
      info_hash = :crypto.strong_rand_bytes(20)
      ia = :crypto.strong_rand_bytes(68)

      {client, client_result, server_result} =
        run_mse_initiator_with_custom_select(info_hash, ia, MSE.crypto_rc4(), pad_d: 4)

      assert {:ok, %{mode: :rc4}} = client_result
      assert {:ok, _} = server_result
      :gen_tcp.close(client)
    end
  end

  describe "Peer.LTEP socket and Sender-key error branches" do
    test "recv_extended/1 uses the default timeout on loopback sockets" do
      {client, server, listen} = loopback_pair()

      on_exit(fn -> close_loopback(client, server, listen) end)

      assert :ok = :gen_tcp.send(server, <<1::32>>)
      assert {:error, :invalid_message} = LTEP.recv_extended(client)
    end

    test "recv_extended surfaces socket recv errors on closed peers" do
      {client, server, listen} = loopback_pair()

      on_exit(fn -> close_loopback(client, server, listen) end)

      assert :ok = :gen_tcp.send(server, <<2::32>>)
      :gen_tcp.close(server)
      assert {:error, _} = LTEP.recv_extended(client, @timeout)
    end

    test "recv_extended via Sender key propagates body recv errors" do
      {client, server, listen, key, sender_pid} = start_inactive_sender_pair()

      on_exit(fn -> cleanup_sender(client, server, listen, sender_pid, key) end)

      assert :ok = :gen_tcp.send(server, <<3::32>>)
      :gen_tcp.close(server)
      assert {:error, _} = LTEP.recv_extended(key, @timeout)
    end

    test "handshake_exchange returns invalid_ltep for malformed peer handshakes" do
      {client, server, listen, key, sender_pid} = start_inactive_sender_pair()

      on_exit(fn -> cleanup_sender(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)

      exchange =
        Task.async(fn ->
          LTEP.handshake_exchange(key, Session.new(), timeout: @timeout)
        end)

      assert {:ok, <<len::32>>} = :gen_tcp.recv(server, 4, @timeout)
      assert {:ok, _our_hs} = :gen_tcp.recv(server, len, @timeout)
      assert :ok = :gen_tcp.send(server, LTEP.extended_message_wire(0, "not-bencode"))

      result = Task.await(exchange, @timeout)

      assert match?({:error, :invalid_ltep}, result) or
               match?({:error, :invalid_handshake}, result)
    end

    test "handshake_exchange on a bare socket rejects invalid extended replies" do
      {client, server, listen} = loopback_pair()
      on_exit(fn -> close_loopback(client, server, listen) end)

      exchange =
        Task.async(fn ->
          LTEP.handshake_exchange(client, Session.new(), timeout: @timeout)
        end)

      assert {:ok, <<len::32>>} = :gen_tcp.recv(server, 4, @timeout)
      assert {:ok, _our_hs} = :gen_tcp.recv(server, len, @timeout)
      assert :ok = :gen_tcp.send(server, LTEP.extended_message_wire(0, <<255>>))
      result = Task.await(exchange, @timeout)

      assert match?({:error, :invalid_ltep}, result) or
               match?({:error, :invalid_handshake}, result)
    end

    test "handshake_exchange returns message_too_large for oversized framed preambles" do
      {client, server, listen, key, sender_pid} = start_inactive_sender_pair()

      on_exit(fn -> cleanup_sender(client, server, listen, sender_pid, key) end)

      assert :ok = Peer.Sender.deactivate(key)
      too_big = LTEP.max_message_size() + 1

      exchange =
        Task.async(fn ->
          LTEP.handshake_exchange(key, Session.new(), timeout: @timeout)
        end)

      assert {:ok, <<len::32>>} = :gen_tcp.recv(server, 4, @timeout)
      assert {:ok, _our_hs} = :gen_tcp.recv(server, len, @timeout)
      assert :ok = :gen_tcp.send(server, <<too_big::32>>)
      assert {:error, :message_too_large} = Task.await(exchange, @timeout)
    end

    test "handshake_exchange socket path returns timeout when the peer stays silent" do
      {client, server, listen} = loopback_pair()
      on_exit(fn -> close_loopback(client, server, listen) end)

      exchange =
        Task.async(fn ->
          LTEP.handshake_exchange(client, Session.new(), timeout: 100)
        end)

      assert {:ok, <<len::32>>} = :gen_tcp.recv(server, 4, @timeout)
      assert {:ok, _our_hs} = :gen_tcp.recv(server, len, @timeout)
      assert {:error, :timeout} = Task.await(exchange, @timeout)
    end
  end

  describe "Peer.Holepunch ETS guards and rendezvous paths" do
    test "attempt_info and clear_pending use the shared pending table" do
      target_ip = {10, 0, 0, 77}
      target_port = 6011
      assert :ok = Holepunch.clear_pending(@hash, target_ip, target_port)
      refute Holepunch.attempt_info(@hash, target_ip, target_port)
      assert :ets.info(:elixir_torrent_holepunch_pending)
    end

    test "maybe_request skips targets that exceeded the rendezvous attempt budget" do
      table = :elixir_torrent_holepunch_pending
      target_ip = {203, 0, 113, 55}
      target_port = 6888
      key = {@hash, target_ip, target_port}
      now = System.monotonic_time(:second)

      Holepunch.clear_pending(@hash, target_ip, target_port)
      :ets.insert(table, {key, now, 4})

      assert :ok =
               Holepunch.maybe_request(
                 @hash,
                 %Peer{ip: target_ip, port: target_port},
                 :timeout
               )

      assert %{count: 4} = Holepunch.attempt_info(@hash, target_ip, target_port)
    end

    test "initiate_connect returns a background task pid immediately" do
      assert {:ok, task} = Holepunch.initiate_connect(@hash, {{127, 0, 0, 1}, 59_125})
      assert is_pid(task)

      on_exit(fn ->
        if Process.alive?(task), do: Process.exit(task, :kill)
      end)
    end

    test "maybe_request ignores non-binary peer endpoints" do
      assert :ok = Holepunch.maybe_request(@hash, %{ip: {1, 1, 1, 1}, port: 1}, :timeout)
    end
  end

  describe "Torrent bencode scanner and v2 parse boundaries" do
    test "parse_file! rejects non-dictionary torrent payloads before slicing info" do
      bad_path = Path.join(File.cwd!(), "scanner-invalid.torrent")
      File.write!(bad_path, "i42e")

      assert_raise ArgumentError, ~r/not a bencoded dictionary/, fn ->
        Torrent.parse_file!(bad_path)
      end
    end

    test "parse_file! raises when v2 merkle metadata cannot be parsed" do
      bad_v2_path = Path.join(File.cwd!(), "bad-v2.torrent")

      File.write!(
        bad_v2_path,
        Bento.encode!(%{
          "info" => %{
            "meta version" => 2,
            "piece length" => 16_384,
            "file tree" => %{"broken" => "not-a-map"},
            "name" => "bad-v2"
          }
        })
      )

      assert_raise ArgumentError, ~r/invalid BitTorrent v2 merkle metadata/, fn ->
        Torrent.parse_file!(bad_v2_path)
      end
    end

    test "parse_file! rejects torrents whose build step fails" do
      empty_v2_path = Path.join(File.cwd!(), "empty-v2.torrent")

      File.write!(
        empty_v2_path,
        Bento.encode!(%{
          "info" => %{
            "meta version" => 2,
            "piece length" => 16_384,
            "file tree" => %{},
            "name" => "empty"
          }
        })
      )

      assert_raise ArgumentError,
                   ~r/invalid BitTorrent v2 merkle metadata: :missing_piece_layers/,
                   fn ->
                     Torrent.parse_file!(empty_v2_path)
                   end
    end
  end

  describe "Torrent supervisor lifecycle in an isolated cwd" do
    test "start_link/1 and delegate accessors work on an isolated torrent stack" do
      {path, hash, name} =
        write_torrent!("delegate-#{System.unique_integer([:positive])}.bin", 24)

      assert {:ok, supervisor} = Torrent.start_link(path)
      on_exit(fn -> TestSupport.Sync.safe_stop(supervisor, 500) end)

      torrent = Torrent.get(hash)
      assert torrent.metadata["info"]["name"] == name
      assert torrent.left == 24
      refute Torrent.downloaded?(hash)
      assert [_entry] = Torrent.list_files(hash)
      assert Torrent.file_count(hash) == 1
      refute Torrent.have?(hash, 0)
      assert Torrent.get_hash(supervisor) == hash
    end
  end

  describe "Torrents lifecycle guards via isolated local stacks" do
    test "download/2 returns the same pid on already_started and list/0 tracks hashes", %{
      download_dir: download_dir
    } do
      {path, hash, _name} = write_torrent!("lifecycle.bin", 16)

      assert {:ok, pid} =
               ElixirTorrent.download(path, download_dir: download_dir, resume: :skip)

      assert {:ok, ^pid} =
               ElixirTorrent.download(path, download_dir: download_dir, resume: :skip)

      assert hash in Torrents.list()
      assert hash in ElixirTorrent.list()
      assert :ok = Torrents.stop_and_serialize(hash)
      refute hash in Torrents.list()
    end

    test "download_magnet/2 rejects invalid magnet URIs through the with-chain" do
      assert {:error, _reason} = Torrents.download_magnet("magnet:?xt=not-a-hash")
    end

    test "stop_and_serialize/1 returns :ok when the torrent is already gone" do
      assert :ok = Torrents.stop_and_serialize(:crypto.strong_rand_bytes(20))
    end

    test "stop_all_and_serialize/0 ignores non-pid DynamicSupervisor children", %{
      download_dir: download_dir
    } do
      {path, hash, _} = write_torrent!("stop-all.bin", 12)
      assert {:ok, _} = Torrents.download(path, download_dir: download_dir, resume: :skip)
      assert hash in Torrents.list()
      assert :ok = Torrents.stop_all_and_serialize()
      refute hash in Torrents.list()
    end
  end

  describe "Peer.Endpoints GenServer branches" do
    test "claim_peer_id handles same endpoint, same pid, and duplicate live peers" do
      hash = :crypto.strong_rand_bytes(20)
      peer_id = :binary.copy(<<9>>, 20)
      n = System.unique_integer([:positive])
      ip_a = {10, 10, div(n, 256), rem(n, 256)}
      ip_b = {10, 11, div(n, 256), rem(n, 256)}
      ip_c = {10, 12, div(n, 256), rem(n, 256)}
      port_a = 6000 + rem(n, 1000)
      port_b = port_a + 1
      port_c = port_a + 2

      holder =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(holder, :stop) end)

      challenger =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(challenger, :stop) end)

      assert :ok = Endpoints.claim_peer_id(hash, peer_id, ip_a, port_a, holder)
      assert :ok = Endpoints.claim_peer_id(hash, peer_id, ip_a, port_a, holder)
      assert :ok = Endpoints.claim_peer_id(hash, peer_id, ip_b, port_b, holder)

      assert {:duplicate, {^ip_b, ^port_b}} =
               Endpoints.claim_peer_id(hash, peer_id, ip_c, port_c, challenger)

      assert Endpoints.count(hash) >= 0
      assert is_list(Endpoints.list(hash))
    end

    test "register replaces dead endpoints and get_pid returns nil for dead pids" do
      hash = :crypto.strong_rand_bytes(20)
      ip = {10, 0, 0, 9}
      port = 6010

      dead =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert :ok = Endpoints.register(hash, ip, port, dead)
      Process.exit(dead, :kill)
      TestSupport.Sync.await_down(Process.monitor(dead), dead, @timeout)

      replacement =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> send(replacement, :stop) end)

      assert :ok = Endpoints.register(hash, ip, port, replacement)
      assert Endpoints.get_pid(hash, ip, port) == replacement
      assert Endpoints.registered?(hash, ip, port)
    end
  end

  describe "Peer.HashWire decode_hashes header error propagation" do
    test "decode_hashes rejects payloads whose trailing hash bytes are misaligned" do
      header = :binary.copy(<<1>>, 48)
      assert {:error, :invalid_hashes_size} = Peer.HashWire.decode_hashes(header <> <<1, 2, 3>>)
    end
  end

  # --- MSE custom responder helpers ------------------------------------------------

  defp run_mse_initiator_with_custom_select(info_hash, ia, select, opts \\ []) do
    pad_d = Keyword.get(opts, :pad_d, 0)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = spawn_custom_mse_responder(listen, info_hash, ia, select, pad_d, self())
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], @timeout)
    client_result = Handshake.initiate(client, info_hash, ia, @timeout)
    server_result = await_custom_mse_server_result(@timeout)
    :gen_tcp.close(listen)
    send(server, :close)
    {client, client_result, server_result}
  end

  defp spawn_custom_mse_responder(listen, info_hash, ia, select, pad_d, parent) do
    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(listen, @timeout)
      result = respond_with_select(sock, info_hash, ia, select, pad_d, @timeout)
      send(parent, {:mse_server, result})

      receive do
        :close -> :gen_tcp.close(sock)
      after
        @timeout -> :gen_tcp.close(sock)
      end
    end)
  end

  defp await_custom_mse_server_result(timeout) do
    receive do
      {:mse_server, result} -> result
    after
      timeout -> flunk("custom MSE responder did not finish")
    end
  end

  defp respond_with_select(socket, info_hash, ia, select, pad_d, timeout) do
    keys = MSE.generate_keypair()

    with {:ok, ya} <- Transport.recv(socket, MSE.key_len(), timeout),
         :ok <- Transport.send(socket, [keys.public, <<>>]),
         s = MSE.shared_secret(ya, keys.private),
         :ok <- scan_for_marker(socket, MSE.req1(s), timeout),
         {:ok, req2_3} <- Transport.recv(socket, 20, timeout) do
      target = MSE.xor(req2_3, MSE.hash("req3", [s]))

      if MSE.hash("req2", [info_hash]) == target do
        finish_respond_with_select(socket, s, info_hash, ia, select, pad_d, timeout)
      else
        {:error, :unknown_info_hash}
      end
    end
  end

  defp finish_respond_with_select(socket, s, info_hash, ia, select, pad_d, timeout) do
    recv_cipher = MSE.new_cipher(MSE.key_a(s, info_hash))
    send_cipher = MSE.new_cipher(MSE.key_b(s, info_hash))

    with {:ok, _ia} <- read_ia_payload(socket, recv_cipher, timeout) do
      select_bytes = <<0::24, select::8>>
      pad = :binary.copy(<<0>>, pad_d)

      payload =
        MSE.crypt(send_cipher, <<MSE.vc()::binary, select_bytes::binary, pad_d::16, pad::binary>>)

      Transport.send(socket, payload)
      {:ok, %{recv: recv_cipher, send: send_cipher, leftover: ia}}
    end
  end

  defp read_ia_payload(socket, cipher, timeout) do
    with {:ok, head} <- Transport.recv(socket, 14, timeout) do
      <<vc::bytes-size(8), _provide::32, pad_len::16>> = MSE.crypt(cipher, head)
      read_ia_body(socket, cipher, vc, pad_len, timeout)
    end
  end

  defp read_ia_body(socket, cipher, vc, pad_len, timeout) do
    if vc == MSE.vc() do
      with {:ok, _pad} <- recv_pad(socket, cipher, pad_len, timeout),
           {:ok, ia_len_enc} <- Transport.recv(socket, 2, timeout) do
        <<ia_len::16>> = MSE.crypt(cipher, ia_len_enc)
        recv_decrypt(socket, cipher, ia_len, timeout)
      end
    else
      {:error, :mse_bad_vc}
    end
  end

  defp recv_pad(_socket, _cipher, 0, _timeout), do: {:ok, <<>>}

  defp recv_pad(socket, cipher, len, timeout) do
    with {:ok, enc} <- Transport.recv(socket, len, timeout) do
      _ = MSE.crypt(cipher, enc)
      {:ok, <<>>}
    end
  end

  defp recv_decrypt(socket, cipher, len, timeout) do
    with {:ok, enc} <- Transport.recv(socket, len, timeout) do
      {:ok, MSE.crypt(cipher, enc)}
    end
  end

  defp scan_for_marker(socket, marker, timeout) do
    case Transport.recv(socket, byte_size(marker), timeout) do
      {:ok, ^marker} -> :ok
      {:ok, window} -> scan_marker_loop(socket, marker, window, 0, timeout)
      {:error, _} = error -> error
    end
  end

  defp scan_marker_loop(_socket, marker, marker, _consumed, _timeout), do: :ok

  defp scan_marker_loop(socket, marker, window, consumed, timeout) do
    if consumed >= 600 do
      {:error, :mse_sync_failed}
    else
      case Transport.recv(socket, 1, timeout) do
        {:ok, byte} ->
          <<_drop::8, rest::binary>> = window
          scan_marker_loop(socket, marker, rest <> byte, consumed + 1, timeout)

        {:error, _} = error ->
          error
      end
    end
  end

  # --- LTEP Sender loopback helpers ------------------------------------------------

  defp start_inactive_sender_pair do
    {client, server, listen} = loopback_pair()
    hash = :crypto.strong_rand_bytes(20)
    id = :crypto.strong_rand_bytes(20)
    key = Peer.make_key(hash, id)

    assert {:ok, _capture} = ControllerCapture.start_link(key, self())
    assert {:ok, sender_pid} = Peer.Sender.start_link([hash, id, client])
    assert :ok = Peer.Transport.controlling_process(client, sender_pid)

    {client, server, listen, key, sender_pid}
  end

  defp cleanup_sender(client, server, listen, sender_pid, key) do
    _ = Peer.Sender.deactivate(key)

    for {sock, close} <- [
          {client, &:gen_tcp.close/1},
          {server, &:gen_tcp.close/1},
          {listen, &:gen_tcp.close/1}
        ] do
      try do
        if is_port(sock), do: close.(sock)
      catch
        :error, _ -> :ok
      end
    end

    for pid <- [sender_pid, ControllerCapture.whereis(key)] do
      TestSupport.Sync.safe_stop(pid, 500)
    end
  end

  defp loopback_pair do
    listen = loopback_listen!()
    {:ok, port} = :inet.port(listen)
    spawn_loopback_acceptor(listen, self())
    client = loopback_connect!(port)
    server = await_loopback_server!(@timeout)
    {client, server, listen}
  end

  defp loopback_listen! do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    listen
  end

  defp spawn_loopback_acceptor(listen, parent) do
    spawn(fn ->
      case :gen_tcp.accept(listen, @timeout) do
        {:ok, server} ->
          :ok = :gen_tcp.controlling_process(server, parent)
          send(parent, {:loopback_server, server})

        error ->
          send(parent, {:loopback_accept_error, error})
      end
    end)
  end

  defp loopback_connect!(port) do
    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], @timeout)

    client
  end

  defp await_loopback_server!(timeout) do
    receive do
      {:loopback_server, server} -> server
      {:loopback_accept_error, error} -> flunk("accept failed: #{inspect(error)}")
    after
      timeout -> flunk("accept timed out")
    end
  end

  defp close_loopback(client, server, listen) do
    for sock <- [client, server, listen] do
      try do
        if is_port(sock), do: :gen_tcp.close(sock)
      catch
        :error, _ -> :ok
      end
    end
  end

  defp write_torrent!(name, length) do
    info = %{
      "length" => length,
      "name" => name,
      "piece length" => 16_384,
      "pieces" => :crypto.hash(:sha, :binary.copy(<<0>>, length)),
      "private" => 1
    }

    info_blob = Bento.encode!(info)
    hash = :crypto.hash(:sha, info_blob)
    path = Path.join(File.cwd!(), "#{name}.torrent")
    File.write!(path, Bento.encode!(%{"info" => info}))
    {path, hash, name}
  end
end
