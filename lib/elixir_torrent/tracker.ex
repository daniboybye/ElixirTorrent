defmodule Tracker do
  require Logger

  alias __MODULE__.{Error, Response}

  @type connection_id :: <<_::64>>
  @type announce :: binary()

  @udp_connect_timeout 15 * trunc(:math.pow(2, 8))
  @udp_protocol_id <<0x41727101980::64>>
  @connect <<0::32>>
  @announce <<1::32>>
  #@scrape <<2::32>>
  @error <<3::32>>
  @bento_nil Bento.encode!(nil)
  @timeout 5 * 60 * 1_000

  # in miliseconds
  @spec udp_connect_timeout() :: pos_integer()
  def udp_connect_timeout(), do: @udp_connect_timeout

  # in seconds
  @spec default_interval() :: pos_integer()
  def default_interval(), do: 30 * 60

  @spec request!(binary(), Torrent.hash()) :: Response.t() | Error.t() | none()
  def request!(<<"http", _::binary>> = announce, hash) do
    # http: and https: clauce
    # obfuscation = Keyword.get(options, :obfuscation, true)
    [uploaded, downloaded, left, event] = 
      Torrent.get(hash, [:uploaded, :downloaded, :left, :event])
    
    %{
      # "sha_ih" => :crypto.hash(:sha, torrent.hash)
      "info_hash" => hash,
      "peer_id" => Peer.id(),
      # obfuscation
      "port" => Acceptor.port(),
      "compact" => 1,
      "uploaded" => uploaded,
      "downloaded" => downloaded,
      "left" => left,
      "event" => Torrent.event_to_string(event),
      "numwant" => numwant(left),
      "key" => Acceptor.key(),
      # obfuscation
      "ip" => Acceptor.ip_string()
    }
    |> URI.encode_query()
    |> (& announce <> "?" <> &1).()
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

  def request!(<<"udp:", _::binary>> = announce, hash) do
    %URI{port: port, host: host} =
      announce
      |> URI.parse()
      |> Map.update!(:port, &if(&1, do: &1, else: 6969))

    {:ok, ip} =
      host
      |> String.to_charlist()
      |> :inet.getaddr(:inet)

    {:ok, socket} = Acceptor.open_udp()

    with {:ok, id} <- PeerDiscovery.connection_id(socket, ip, port),
         do: udp_announce(socket, ip, port, id, hash)
  end

  @spec udp_connect(port(), :inet.ip_address(), :inet.port_number()) ::
          connection_id() | Error.t() | no_return()
  def udp_connect(socket, ip, port) do
    generate_transaction_id()
    |> do_udp_connect(socket, ip, port, 15)
  end

  @spec do_udp_connect(
          <<_::32>>,
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
        [@udp_protocol_id, @connect, transaction_id]
      )
  	
    case :gen_udp.recv(socket, 0, timeout * 1_000) do
      {:ok, {^ip, ^port, <<@connect, ^transaction_id::bytes-size(4), connection_id::bytes-size(8)>>}} ->
        connection_id

      {:ok, {^ip, ^port, <<@error, ^transaction_id::bytes-size(4), reason::binary>>}} ->
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
          Torrent.hash()
        ) :: Response.t() | no_return()
  defp udp_announce(socket, ip, port, connection_id, hash) do
    transaction_id = generate_transaction_id()
    
    message = make_msg_udp_request(connection_id, transaction_id, hash)

    :ok = :gen_udp.send(socket, ip, port, message)

    case :gen_udp.recv(socket, 0, @timeout) do
      {:ok, {^ip, ^port, <<@error, ^transaction_id::bytes-size(4), reason::binary>>}} ->
        %Error{reason: reason}

      {:ok,
       {^ip, ^port,
        <<@announce, ^transaction_id::bytes-size(4), interval::32, leechers::32, seeders::32, peers::binary>>}} ->
        %Response{
          interval: interval,
          complete: seeders,
          incomplete: leechers,
          peers: to_peers(peers)
        }
    end
  end

  @moduledoc """
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
        {:ok, {^ip, ^port, <<@error::bytes-size(4), ^transaction_id::bytes-size(4), reason::binary>>}} ->
          %Error{reason: reason}

        {:ok, {^ip, ^port, <<@scrape::bytes-size(4), ^transaction_id::bytes-size(4), _::binary>>}} ->
          # TODO
          :ok
      end
    end
  """

  defp to_peers(bin) when is_binary(bin) do
    case tuple_size(Acceptor.ip()) do
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

  defp make_msg_udp_request(connection_id, transaction_id, hash) do
    [downloaded, left, uploaded, event] = 
      Torrent.get(hash, [:downloaded, :left, :uploaded, :event])

    ip = Acceptor.ip_binary()
    ip_field = if byte_size(ip) === 4, do: ip, else: <<0::32>>
    [
      connection_id,
      @announce,
      transaction_id,
      hash,
      Peer.id(),
      <<downloaded::64>>,
      <<left::64>>,
      <<uploaded::64>>,
      <<event::32>>,
      ip_field,
      Acceptor.key(),
      <<numwant(left)::32>>,
      <<Acceptor.port()::16>>
    ]
  end

  @spec generate_transaction_id() :: <<_::32>>
  defp generate_transaction_id(), 
    do: :crypto.strong_rand_bytes(4)

  defp numwant(0), do: 0

  defp numwant(_), do: 60
end
