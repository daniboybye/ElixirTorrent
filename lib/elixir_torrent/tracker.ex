defmodule Tracker do
  require Logger

  alias __MODULE__.{Error, Response}

  @type key :: non_neg_integer()
  @type connection_id :: <<_::64>>
  @type announce :: binary()

  @udp_connect_timeout 15 * trunc(:math.pow(2, 8))
  @udp_protocol_id <<0x41727101980::64>>
  @connect <<0::32>>
  @announce <<1::32>>
  @scrape <<2::32>>
  @error <<3::32>>
  @bento_nil Bento.encode!(nil)
  @timeout 25_000

  @spec udp_connect_timeout() :: pos_integer()
  def udp_connect_timeout(), do: @udp_connect_timeout

  @spec default_interval() :: pos_integer()
  def default_interval(), do: 5 * 60

  @spec request!(announce(), Torrent.t(), Peer.id(), :inet.port_number(), key()) ::
          Response.t() | Error.t() | no_return()
  def request!(<<"http:", _::binary>> = announce, torrent, peer_id, port, key) do
    # obfuscation = Keyword.get(options, :obfuscation, true)

    %{
      # "sha_ih" => :crypto.hash(:sha, torrent.hash)
      "info_hash" => torrent.hash,
      "peer_id" => peer_id,
      # obfuscation
      "port" => port,
      "compact" => 1,
      "uploaded" => torrent.uploaded,
      "downloaded" => torrent.downloaded,
      "left" => torrent.left,
      "event" => Torrent.event_to_string(torrent.event),
      "numwant" => numwant(torrent.left),
      # "key" => key,
      # obfuscation
      "ip" => Acceptor.ip_string()
    }
    |> URI.encode_query()
    |> (&<<announce::binary, "?", &1::binary>>).()
    |> HTTPoison.get!([], timeout: @timeout, recv_timeout: @timeout)
    |> Map.fetch!(:body)
    |> Bento.decode!()
    |> case do
      %{"failure reason" => reason} = map ->
        %Error{
          reason: reason,
          retry_in: Map.get(map, "retry in")
        }

      map ->
        %Response{
          interval: Map.get(map, "interval", default_interval()),
          complete: Map.get(map, "complete", 0),
          incomplete: Map.get(map, "incomplete", 0),
          external_ip: Map.get(map, "external ip", @bento_nil) |> Bento.decode!(),
          peers: Map.get(map, "peers", []) |> to_peers()
        }
    end
  end

  def request!(<<"udp:", _::binary>> = announce, torrent, peer_id, my_port, key) do
    %URI{port: port, host: host} =
      announce
      |> URI.parse()
      |> Map.update!(:port, &if(&1, do: &1, else: 6969))

    {:ok, ip} =
      host
      |> String.to_charlist()
      |> :inet.getaddr(:inet)

    socket = Acceptor.open_udp()

    case PeerDiscovery.connection_id(announce, socket, ip, port) do
      %Error{} = error ->
        error

      id ->
        udp_announce(socket, ip, port, id, torrent, peer_id, my_port, key)
    end
  end

  @spec udp_connect(port(), :inet.ip_address(), :inet.port_number()) ::
          connection_id() | Error.t() | no_return()
  def udp_connect(socket, ip, port) do
    generate_transaction_id()
    |> do_udp_connect(socket, ip, port, 15)
  end

  @spec do_udp_connect(
          non_neg_integer(),
          port(),
          :inet.ip_address(),
          non_neg_integer(),
          pos_integer()
        ) :: connection_id() | Error.t() | no_return()
  defp do_udp_connect(_, _, _, _, timeout) when timeout > @udp_connect_timeout do
    %Error{reason: :timeout}
  end

  defp do_udp_connect(transaction_id, socket, ip, port, timeout) do
    :ok =
      :gen_udp.send(
        socket,
        ip,
        port,
        [@udp_protocol_id, @connect, <<transaction_id::32>>]
      )

    case :gen_udp.recv(socket, 0, timeout * 1_000) do
      {:ok, {^ip, ^port, <<@connect, ^transaction_id::32, connection_id::bytes-size(8)>>}} ->
        connection_id

      {:ok, {^ip, ^port, <<@error, ^transaction_id::32, reason::binary>>}} ->
        %Error{reason: reason}

      {:error, :timeout} ->
        do_udp_connect(transaction_id, socket, ip, port, timeout * 2)
    end
  end

  @spec udp_announce(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          connection_id(),
          Torrent.t(),
          Peer.id(),
          :inet.port_number(),
          key()
        ) :: Response.t() | no_return()
  defp udp_announce(socket, ip, port, connection_id, torrent, peer_id, my_port, key) do
    transaction_id = generate_transaction_id()

    message = [
      connection_id,
      @announce,
      <<transaction_id::32>>,
      torrent.hash,
      peer_id,
      <<torrent.downloaded::64>>,
      <<torrent.left::64>>,
      <<torrent.uploaded::64>>,
      <<torrent.event::32>>,
      ip(),
      <<key::32>>,
      <<numwant(torrent.left)::32>>,
      <<my_port::16>>
    ]

    :ok = :gen_udp.send(socket, ip, port, message)

    case :gen_udp.recv(socket, 0, @timeout) do
      {:ok, {^ip, ^port, <<@error, ^transaction_id::32, reason::binary>>}} ->
        %Error{reason: reason}

      {:ok,
       {^ip, ^port,
        <<@announce, ^transaction_id::32, interval::32, leechers::32, seeders::32, peers::binary>>}} ->
        %Response{
          interval: interval,
          complete: seeders,
          incomplete: leechers,
          peers: to_peers(peers)
        }
    end
  end

  @spec ip() :: <<_::32>>
  defp ip() do
    Acceptor.ip_binary()
    |> byte_size()
    |> case do
      4 ->
        Acceptor.ip_binary()

      _ ->
        <<0::32>>
    end
  end

  @docmodule """
    scrape request:
    Offset          Size            Name            Value
    0               64-bit integer  connection_id
    8               32-bit integer  action          2 // scrape
    12              32-bit integer  transaction_id
    16 + 20 * n     20-byte string  info_hash
    16 + 20 * N

    scrape response:
    Offset      Size            Name            Value
    0           32-bit integer  action          2 // scrape
    4           32-bit integer  transaction_id
    8 + 12 * n  32-bit integer  seeders
    12 + 12 * n 32-bit integer  completed
    16 + 12 * n 32-bit integer  leechers
    8 + 12 * N
    

    def udp_scrape(socket, ip, port, connection_id, list) do
      transaction_id = generate_transaction_id()

      :ok =
        :gen_udp.send(
          socket,
          ip,
          port,
          :binary.list_to_bin([connection_id, @scrape, transaction_id | list])
        )

      case :gen_udp.recv(socket, 0, @timeout) do
        {:ok, {^ip, ^port, <<@error, ^transaction_id::32, reason::binary>>}} ->
          %Error{reason: reason}

        {:ok, {^ip, ^port, <<@scrape, ^transaction_id::32, _::binary>>}} ->
          # TODO
          :ok
      end
    end
  """

  defp to_peers(bin) when is_binary(bin) do
    Acceptor.ip()
    |> tuple_size()
    |> case do
      4 -> do_parse_ipv4([], bin)
      8 -> do_parse_ipv6([], bin)
    end
  end

  defp to_peers(list) when is_list(list) do
    Enum.map(
      list,
      fn %{"peer id" => id, "port" => port, "ip" => ip} ->
        %Peer{id: id, port: port, ip: ip}
      end
    )
  end

  defp do_parse_ipv4(res, <<>>), do: res

  defp do_parse_ipv4(res, <<ip1, ip2, ip3, ip4, port::16, bin::binary>>) do
    [%Peer{port: port, ip: Enum.join([ip1, ip2, ip3, ip4], ".")} | res]
    |> do_parse_ipv4(bin)
  end

  defp do_parse_ipv6(res, <<>>), do: res

  defp do_parse_ipv6(
         res,
         <<ip1::16, ip2::16, ip3::16, ip4::16, ip5::16, ip6::16, ip7::16, ip8::16, port::16,
           bin::binary>>
       ) do
    [%Peer{port: port, ip: Enum.join([ip1, ip2, ip3, ip4, ip5, ip6, ip7, ip8], ".")} | res]
    |> do_parse_ipv6(bin)
  end

  @spec generate_transaction_id() :: non_neg_integer()
  defp generate_transaction_id() do
    :math.pow(2, 32)
    |> trunc()
    |> :rand.uniform()
    |> Kernel.-(1)
  end

  defp numwant(0), do: 0

  defp numwant(_), do: 100
end
