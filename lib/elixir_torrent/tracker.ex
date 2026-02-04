defmodule Tracker do
  require Logger

  alias __MODULE__.{Error, Response}

  @type connection_id :: <<_::64>>
  @type announce :: binary()

  @udp_connect_timeout 15 * trunc(:math.pow(2, 8))
  @udp_protocol_id <<0x41727101980::64>>
  @connect <<0::32>>
  @announce <<1::32>>
  # @scrape <<2::32>>
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
      "key" => Acceptor.key()
    }
    |> URI.encode_query()
    |> (&(announce <> "?" <> &1)).()
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
        peers_v4 = Map.get(map, "peers", []) |> to_peers_v4()
        peers_v6 = Map.get(map, "peers6", []) |> to_peers_v6()

        %Response{
          interval: Map.get(map, "interval", default_interval()),
          complete: Map.get(map, "complete", 0),
          incomplete: Map.get(map, "incomplete", 0),
          external_ip: Map.get(map, "external ip", @bento_nil) |> Bento.decode!(),
          peers: peers_v4 ++ peers_v6
        }
    end
  end

  def request!(<<"udp:", _::binary>> = announce, hash) do
    %URI{port: port, host: host} =
      announce
      |> URI.parse()
      |> Map.update!(:port, &if(&1, do: &1, else: 6969))

    {:ok, ip, family} = resolve_host(host)

    {:ok, socket} = Acceptor.open_udp(family)

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
      {:ok,
       {^ip, ^port, <<@connect, ^transaction_id::bytes-size(4), connection_id::bytes-size(8)>>}} ->
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
        <<@announce, ^transaction_id::bytes-size(4), interval::32, leechers::32, seeders::32,
          peers::binary>>}} ->
        %Response{
          interval: interval,
          complete: seeders,
          incomplete: leechers,
          peers: to_peers_v4(peers)
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

  # HTTP trackers typically return:
  # - "peers": compact IPv4 peers (6-byte entries) when compact=1 (BEP 23)
  # - "peers6": compact IPv6 peers (18-byte entries) (BEP 7, widely deployed)
  @spec to_peers_v4(binary() | list()) :: list(Peer.t())
  defp to_peers_v4(bin) when is_binary(bin), do: parse_compact_ipv4([], bin)
  defp to_peers_v4(list) when is_list(list), do: parse_peer_dicts(list)

  @spec to_peers_v6(binary() | list() | any()) :: list(Peer.t())
  defp to_peers_v6(bin) when is_binary(bin), do: parse_compact_ipv6([], bin)
  defp to_peers_v6(list) when is_list(list), do: parse_peer_dicts(list)
  defp to_peers_v6(_), do: []

  @spec parse_compact_ipv4(list(Peer.t()), binary()) :: list(Peer.t())
  defp parse_compact_ipv4(res, <<>>), do: res

  defp parse_compact_ipv4(res, <<a, b, c, d, port::16, rest::binary>>) do
    [%Peer{ip: {a, b, c, d}, port: port} | res]
    |> parse_compact_ipv4(rest)
  end

  @spec parse_compact_ipv6(list(Peer.t()), binary()) :: list(Peer.t())
  defp parse_compact_ipv6(res, <<>>), do: res

  defp parse_compact_ipv6(
         res,
         <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16,
           rest::binary>>
       ) do
    [%Peer{ip: {s1, s2, s3, s4, s5, s6, s7, s8}, port: port} | res]
    |> parse_compact_ipv6(rest)
  end

  @spec parse_peer_dicts(list(map())) :: list(Peer.t())
  defp parse_peer_dicts(list) do
    Enum.flat_map(list, fn
      %{"peer id" => id, "port" => port, "ip" => ip} ->
        case parse_ip(ip) do
          {:ok, ip_tuple} -> [%Peer{id: id, port: port, ip: ip_tuple}]
          :error -> []
        end

      %{"port" => port, "ip" => ip} ->
        case parse_ip(ip) do
          {:ok, ip_tuple} -> [%Peer{port: port, ip: ip_tuple}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  @spec parse_ip(binary() | :inet.ip_address()) :: {:ok, :inet.ip_address()} | :error
  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}

  defp parse_ip(ip) when is_binary(ip) do
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :error
    end
  end

  @spec resolve_host(binary()) :: {:ok, :inet.ip_address(), :inet | :inet6}
  defp resolve_host(host) do
    char_host = String.to_charlist(host)

    # Pragmatic choice: prefer IPv4 for UDP trackers (BEP 15), because many trackers
    # either don't support IPv6 reliably or have broken AAAA records. We still support
    # IPv6 where it works by falling back to :inet6.
    case :inet.getaddr(char_host, :inet) do
      {:ok, ip} ->
        {:ok, ip, :inet}

      _ ->
        {:ok, ip} = :inet.getaddr(char_host, :inet6)
        {:ok, ip, :inet6}
    end
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
