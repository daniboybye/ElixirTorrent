defmodule Tracker do
  require Logger

  alias __MODULE__.{Error, Response, UDP}

  @type connection_id :: <<_::64>>
  @type announce :: binary()
  @type stats :: :auto | keyword()
  @type scrape_stats :: UDP.scrape_stats()

  @bento_nil Bento.encode!(nil)
  @timeout 5 * 60 * 1_000
  @udp_max_backoff_attempt UDP.max_backoff_attempt()

  # in seconds
  @spec default_interval() :: pos_integer()
  def default_interval(), do: 30 * 60

  @type request_opts :: [
          max_udp_attempts: 0..8,
          http_timeout_ms: pos_integer()
        ]

  @spec request!(binary(), Torrent.hash(), stats() | :auto, request_opts()) ::
          Response.t() | Error.t() | none()
  def request!(announce, hash, stats \\ :auto, opts \\ [])

  def request!(<<"http", _::binary>> = announce, hash, stats, opts) do
    with {:ok, {uploaded, downloaded, left, event}} <- resolve_stats(hash, stats) do
      do_http_request!(announce, hash, uploaded, downloaded, left, event, opts)
    else
      :skip ->
        Logger.debug(
          "[tracker_announce] deferred hash=#{Torrent.hex_encoded_hash(hash)} reason=model_not_ready"
        )

        nil
    end
  end

  def request!(<<"udp:", _::binary>> = announce, hash, stats, opts) do
    # BEP 15: optional path after host:port is ignored for UDP trackers.
    %URI{port: port, host: host} =
      announce
      |> URI.parse()
      |> Map.update!(:port, &if(&1, do: &1, else: 6969))

    case resolve_host(host) do
      {:ok, ip, family} ->
        {:ok, socket} = Acceptor.open_udp(family)

        with_connection_id(socket, ip, port, fn id ->
          udp_announce(socket, ip, port, id, hash, stats, family, opts)
        end)

      {:error, reason} ->
        Logger.warning("UDP tracker DNS resolution failed host=#{host} reason=#{inspect(reason)}")
        %Error{reason: {:dns, host, reason}, retry_in: "never"}
    end
  end

  defp do_http_request!(announce, hash, uploaded, downloaded, left, event, opts) do
    query =
      %{
        "info_hash" => hash,
        "peer_id" => Peer.id(),
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

    url = announce <> "?" <> query

    %{inet: ip4, inet6: ip6} = Acceptor.primary_ips()

    responses =
      []
      |> maybe_http_announce(url, :inet, ip4, opts)
      |> maybe_http_announce(url, :inet6, ip6, opts)

    merge_http_announces(responses)
  end

  @spec with_connection_id(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          (connection_id() -> term())
        ) :: term()
  defp with_connection_id(socket, ip, port, fun) when is_function(fun, 1) do
    case safe_connection_id(socket, ip, port) do
      {:ok, id} ->
        retry_on_expired_connection_id(socket, ip, port, fun, fun.(id))

      %Error{} = error ->
        error

      :error ->
        %Error{reason: :connection_id_unavailable}
    end
  end

  defp safe_connection_id(socket, ip, port) do
    PeerDiscovery.connection_id(socket, ip, port)
  catch
    :exit, reason ->
      %Error{reason: connection_id_exit_reason(reason), retry_in: 60}
  end

  defp connection_id_exit_reason(:timeout), do: :timeout
  defp connection_id_exit_reason({:timeout, _}), do: :timeout
  defp connection_id_exit_reason(reason), do: reason

  # BEP 15 § UDP connections — stale connection_id yields tracker error; invalidate and retry once.
  @spec retry_on_expired_connection_id(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          (connection_id() -> term()),
          term()
        ) :: term()
  defp retry_on_expired_connection_id(_socket, _ip, _port, _fun, result)
       when not is_struct(result, Error),
       do: result

  defp retry_on_expired_connection_id(socket, ip, port, fun, %Error{reason: reason} = error) do
    if connection_id_expired?(reason) do
      :ok = PeerDiscovery.invalidate_connection_id(socket, ip, port)

      case safe_connection_id(socket, ip, port) do
        {:ok, id} -> fun.(id)
        other -> other
      end
    else
      error
    end
  end

  @spec connection_id_expired?(term()) :: boolean()
  defp connection_id_expired?(reason) when is_binary(reason) do
    down = String.downcase(reason)
    String.contains?(down, "connection id") or String.contains?(down, "expired")
  end

  defp connection_id_expired?(_), do: false

  @spec maybe_http_announce(
          list(Response.t() | Error.t()),
          binary(),
          :inet | :inet6,
          any(),
          request_opts()
        ) ::
          list(Response.t() | Error.t())
  defp maybe_http_announce(acc, _url, _family, nil, _opts), do: acc

  defp maybe_http_announce(acc, url, family, ip, opts) do
    [http_announce(url, family, ip, opts) | acc]
  end

  @spec http_announce(binary(), :inet | :inet6, :inet.ip_address(), request_opts()) ::
          Response.t() | Error.t()
  defp http_announce(url, family, ip, opts) do
    timeout_ms = Keyword.get(opts, :http_timeout_ms, @timeout)

    http_opts = [
      timeout: timeout_ms,
      recv_timeout: timeout_ms,
      hackney: http_hackney_opts(family, ip)
    ]

    try do
      case HTTPoison.get(url, [], http_opts) do
        {:ok, %HTTPoison.Response{status_code: code, body: body, headers: headers}}
        when code in 200..299 ->
          decode_tracker_body(body, url, family, ip, headers, http_opts, 0)

        {:ok, %HTTPoison.Response{status_code: code}} ->
          %Error{reason: {:http_status, code}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          %Error{reason: reason}

        other ->
          %Error{reason: other}
      end
    rescue
      e in CaseClauseError ->
        if badarg_clause?(e) do
          %Error{reason: :badarg}
        else
          reraise e, __STACKTRACE__
        end
    catch
      :exit, reason ->
        %Error{reason: reason}

      :error, :badarg ->
        %Error{reason: :badarg}
    end
  end

  # Bind outbound HTTP to the chosen local address on IPv4. Hackney/HTTPoison raise
  # CaseClauseError on bare :badarg when given an IPv6 tuple in connect_options, so IPv6
  # announces use the :inet6 socket family and the OS default route instead (BEP 7).
  @spec http_hackney_opts(:inet | :inet6, :inet.ip_address()) :: keyword()
  defp http_hackney_opts(:inet, ip), do: [connect_options: [{:ip, ip}]]
  defp http_hackney_opts(:inet6, _ip), do: [connect_options: [:inet6]]

  @spec badarg_clause?(CaseClauseError.t()) :: boolean()
  defp badarg_clause?(%CaseClauseError{term: :badarg}), do: true
  defp badarg_clause?(_), do: false

  @spec decode_tracker_body(
          binary(),
          binary(),
          :inet | :inet6,
          :inet.ip_address(),
          list(),
          keyword(),
          0 | 1
        ) :: Response.t() | Error.t()
  defp decode_tracker_body(body, url, family, ip, headers, opts, depth) do
    try do
      body
      |> Bento.decode!()
      |> decode_http_response()
    rescue
      _e in [Bento.SyntaxError] ->
        content_type = header_value(headers, "content-type")
        ip_str = ip |> :inet.ntoa() |> List.to_string()
        preview = binary_part(body, 0, min(byte_size(body), 500))

        Logger.warning(
          "HTTP tracker returned non-bencode body url=#{url} family=#{family} ip=#{ip_str} content_type=#{inspect(content_type)} bytes=#{byte_size(body)} preview=#{inspect(preview)}"
        )

        # Some tracker endpoints return HTML and JS redirects.
        # Follow one redirect hop before giving up.
        case {depth, extract_js_redirect(body)} do
          {0, {:ok, redirect}} ->
            next_url = absolute_redirect(url, redirect)
            Logger.info("HTTP tracker redirect follow url=#{next_url}")

            case HTTPoison.get(next_url, [], opts) do
              {:ok, %HTTPoison.Response{status_code: code, body: body2, headers: headers2}}
              when code in 200..299 ->
                decode_tracker_body(body2, next_url, family, ip, headers2, opts, 1)

              {:ok, %HTTPoison.Response{status_code: code}} ->
                %Error{reason: {:http_status, code}}

              {:error, %HTTPoison.Error{reason: reason}} ->
                %Error{reason: reason}
            end

          _ ->
            %Error{reason: :non_bencoded_response, retry_in: "never"}
        end
    end
  end

  @spec header_value(list(), binary()) :: binary() | nil
  defp header_value(headers, key) do
    down = String.downcase(key)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == down, do: v

      {k, v} when is_list(k) and is_list(v) ->
        if String.downcase(List.to_string(k)) == down, do: List.to_string(v)

      _ ->
        nil
    end)
  end

  @spec extract_js_redirect(binary()) :: {:ok, binary()} | :error
  defp extract_js_redirect(body) do
    case Regex.run(~r/window\\.location\\.href\\s*=\\s*\"([^\"]+)\"/, body,
           capture: :all_but_first
         ) do
      [path] when is_binary(path) and byte_size(path) > 0 -> {:ok, path}
      _ -> :error
    end
  end

  @spec absolute_redirect(binary(), binary()) :: binary()
  defp absolute_redirect(base_url, redirect) do
    base_url
    |> URI.parse()
    |> URI.merge(redirect)
    |> URI.to_string()
  end

  @spec decode_http_response(map()) :: Response.t() | Error.t()
  defp decode_http_response(%{"failure reason" => reason} = map) do
    %Error{
      reason: reason,
      retry_in: Map.get(map, "retry in")
    }
  end

  defp decode_http_response(map) when is_map(map) do
    peers_v4 = Map.get(map, "peers", []) |> to_peers_v4()
    peers_v6 = Map.get(map, "peers6", []) |> to_peers_v6()

    %Response{
      interval: Map.get(map, "interval", default_interval()),
      min_interval: Map.get(map, "min interval"),
      complete: Map.get(map, "complete", 0),
      incomplete: Map.get(map, "incomplete", 0),
      external_ip: Map.get(map, "external ip", @bento_nil) |> Bento.decode!(),
      peers: peers_v4 ++ peers_v6
    }
  end

  @spec merge_http_announces(list(Response.t() | Error.t())) :: Response.t() | Error.t()
  defp merge_http_announces(list) do
    {oks, errs} = Enum.split_with(list, &match?(%Response{}, &1))

    case oks do
      [%Response{} | _] ->
        Enum.reduce(oks, nil, fn resp, acc -> merge_resp(acc, resp) end)

      [] ->
        # if both failed, return "best" error (first)
        List.first(errs) || %Error{reason: :unknown}
    end
  end

  @spec merge_resp(Response.t() | nil, Response.t()) :: Response.t()
  defp merge_resp(nil, %Response{} = b), do: b

  defp merge_resp(%Response{} = a, %Response{} = b) do
    peers =
      (a.peers ++ b.peers)
      |> Enum.uniq_by(&{&1.ip, &1.port})

    %Response{
      interval: min(a.interval, b.interval),
      complete: max(a.complete, b.complete),
      incomplete: max(a.incomplete, b.incomplete),
      external_ip: a.external_ip || b.external_ip,
      peers: peers
    }
  end

  @doc """
  BEP 15 § Connect — obtain a connection_id with exponential backoff retransmission.

  Sends action=0 with magic `protocol_id`, validates action/transaction_id on response,
  and returns `%Tracker.Error{}` (including `reason: :timeout`) instead of raising.
  """
  @spec udp_connect(port(), :inet.ip_address(), :inet.port_number()) ::
          connection_id() | Error.t()
  def udp_connect(socket, ip, port) do
    transaction_id = generate_transaction_id()
    packet = UDP.encode_connect(transaction_id)
    do_udp_request(socket, ip, port, packet, transaction_id, expected: :connect, attempt: 0)
  end

  @doc """
  BEP 15 § Scrape — query seeders/completed/leechers for up to 74 info_hashes per request.

  Multiple hashes are chunked automatically. Returns a map of hash => stats or `%Tracker.Error{}`.
  """
  @spec udp_scrape(port(), :inet.ip_address(), :inet.port_number(), [Torrent.hash()]) ::
          %{Torrent.hash() => scrape_stats()} | Error.t()
  def udp_scrape(_socket, _ip, _port, []), do: %{}

  def udp_scrape(socket, ip, port, hashes) do
    with_connection_id(socket, ip, port, fn connection_id ->
      hashes
      |> Enum.chunk_every(UDP.max_scrape_hashes())
      |> Enum.reduce_while(%{}, fn chunk, acc ->
        case do_udp_scrape(socket, ip, port, connection_id, chunk) do
          {:ok, chunk_map} -> {:cont, Map.merge(acc, chunk_map)}
          %Error{} = error -> {:halt, error}
        end
      end)
      |> case do
        %Error{} = error -> error
        map -> map
      end
    end)
  end

  @spec do_udp_scrape(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          connection_id(),
          [Torrent.hash()]
        ) :: {:ok, %{Torrent.hash() => scrape_stats()}} | Error.t()
  defp do_udp_scrape(socket, ip, port, connection_id, hashes) do
    transaction_id = generate_transaction_id()
    packet = UDP.encode_scrape(connection_id, transaction_id, hashes)

    case do_udp_request(socket, ip, port, packet, transaction_id,
           expected: :scrape,
           hash_count: length(hashes),
           attempt: 0
         ) do
      stats_list when is_list(stats_list) ->
        {:ok, Map.new(Enum.zip(hashes, stats_list))}

      %Error{} = error ->
        error
    end
  end

  @spec udp_announce(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          connection_id(),
          Torrent.hash(),
          stats(),
          :inet | :inet6,
          request_opts()
        ) :: Response.t() | Error.t()
  defp udp_announce(socket, ip, port, connection_id, hash, stats, family, opts) do
    case resolve_stats(hash, stats) do
      :skip ->
        %Error{reason: :model_not_ready, retry_in: "short"}

      {:ok, announce_stats} ->
        do_udp_announce(socket, ip, port, connection_id, hash, announce_stats, family, opts)
    end
  end

  defp do_udp_announce(socket, ip, port, connection_id, hash, announce_stats, family, opts) do
    transaction_id = generate_transaction_id()
    packet = encode_udp_announce(connection_id, transaction_id, hash, announce_stats)
    max_attempts = Keyword.get(opts, :max_udp_attempts, @udp_max_backoff_attempt)

    case do_udp_request(socket, ip, port, packet, transaction_id,
           expected: :announce,
           family: family,
           attempt: 0,
           max_udp_attempts: max_attempts
         ) do
      %Response{} = response -> response
      %Error{} = error -> error
      {:error, reason} -> %Error{reason: reason}
      other -> %Error{reason: other}
    end
  end

  @spec do_udp_request(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          iodata(),
          <<_::32>>,
          keyword()
        ) :: connection_id() | Response.t() | [scrape_stats()] | Error.t()
  defp do_udp_request(socket, ip, port, packet, transaction_id, opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    max_attempts = Keyword.get(opts, :max_udp_attempts, @udp_max_backoff_attempt)

    if attempt > max_attempts do
      %Error{reason: :timeout}
    else
      :ok = :gen_udp.send(socket, ip, port, packet)
      timeout_ms = udp_backoff_ms(attempt)

      case udp_recv_until(socket, ip, port, transaction_id, timeout_ms, opts) do
        {:ok, result} ->
          result

        {:error, :timeout} ->
          do_udp_request(
            socket,
            ip,
            port,
            packet,
            transaction_id,
            Keyword.merge(opts, attempt: attempt + 1, max_udp_attempts: max_attempts)
          )

        {:error, reason} when is_binary(reason) ->
          %Error{reason: reason}

        {:error, reason} ->
          %Error{reason: reason}
      end
    end
  end

  @spec udp_recv_until(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          <<_::32>>,
          non_neg_integer(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  defp udp_recv_until(socket, ip, port, transaction_id, timeout_ms, opts) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    recv_loop(socket, ip, port, transaction_id, deadline_ms, opts)
  end

  defp recv_loop(socket, ip, port, transaction_id, deadline_ms, opts) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      do_recv_loop(remaining_ms, deadline_ms, socket, ip, port, transaction_id, opts)
    end
  end

  defp do_recv_loop(remaining_ms, deadline_ms, socket, ip, port, transaction_id, opts) do
    case :gen_udp.recv(socket, 0, remaining_ms) do
      {:ok, {^ip, ^port, body}} ->
        case UDP.classify_response(body, transaction_id, opts) do
          :ignore ->
            recv_loop(socket, ip, port, transaction_id, deadline_ms, opts)

          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec encode_udp_announce(
          connection_id(),
          <<_::32>>,
          Torrent.hash(),
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), 0..3}
        ) :: iodata()
  defp encode_udp_announce(connection_id, transaction_id, hash, {uploaded, downloaded, left, event}) do

    ip = Acceptor.ip_binary()

    # BEP 15 § Announce / IPv6 — IP address field is 32 bits and must be 0 under IPv6.
    ip_field = if byte_size(ip) === 4, do: ip, else: <<0::32>>

    UDP.encode_announce(connection_id, transaction_id, hash, Peer.id(),
      uploaded: uploaded,
      downloaded: downloaded,
      left: left,
      event: event,
      ip_field: ip_field,
      key: Acceptor.key(),
      num_want: numwant(left),
      port: Acceptor.port()
    )
  end

  # HTTP trackers typically return:
  # - "peers": compact IPv4 peers (6-byte entries) when compact=1 (BEP 23)
  # - "peers6": compact IPv6 peers (18-byte entries) (BEP 7, widely deployed)
  @spec to_peers_v4(binary() | list()) :: list(Peer.t())
  defp to_peers_v4(bin) when is_binary(bin), do: UDP.parse_compact_peers(bin, :inet)
  defp to_peers_v4(list) when is_list(list), do: parse_peer_dicts(list)

  @spec to_peers_v6(binary() | list() | any()) :: list(Peer.t())
  defp to_peers_v6(bin) when is_binary(bin), do: UDP.parse_compact_peers(bin, :inet6)
  defp to_peers_v6(list) when is_list(list), do: parse_peer_dicts(list)
  defp to_peers_v6(_), do: []

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

  @spec resolve_host(binary()) :: {:ok, :inet.ip_address(), :inet | :inet6} | {:error, term()}
  defp resolve_host(host) do
    char_host = String.to_charlist(host)

    # BEP 15 is IPv4-focused; prefer A records, fall back to AAAA (18-byte peer stride in response).
    case :inet.getaddr(char_host, :inet) do
      {:ok, ip} ->
        {:ok, ip, :inet}

      {:error, reason_v4} ->
        case :inet.getaddr(char_host, :inet6) do
          {:ok, ip} -> {:ok, ip, :inet6}
          {:error, _reason_v6} -> {:error, reason_v4}
        end
    end
  end

  @spec resolve_stats(Torrent.hash(), :auto | keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer(), 0..3}} | :skip
  defp resolve_stats(hash, :auto) do
    if Torrent.Model.has_hash?(hash) do
      try do
        [uploaded, downloaded, left, event] =
          Torrent.get(hash, [:uploaded, :downloaded, :left, :event])

        {:ok, {uploaded, downloaded, left, event}}
      catch
        :exit, _ -> :skip
      end
    else
      :skip
    end
  end

  defp resolve_stats(_hash, stats) when is_list(stats) do
    uploaded = Keyword.get(stats, :uploaded, 0)
    downloaded = Keyword.get(stats, :downloaded, 0)
    left = Keyword.get(stats, :left, Magnet.metadata_left())
    event = Keyword.get(stats, :event, Torrent.started())
    {:ok, {uploaded, downloaded, left, event}}
  end

  @spec generate_transaction_id() :: <<_::32>>
  defp generate_transaction_id(),
    do: :crypto.strong_rand_bytes(4)

  # BEP 15 § Time outs — overridable in test via `:udp_backoff_ms` application env.
  @spec udp_backoff_ms(0..8) :: pos_integer()
  defp udp_backoff_ms(attempt) do
    case Application.get_env(:elixir_torrent, :udp_backoff_ms) do
      fun when is_function(fun, 1) -> fun.(attempt)
      _ -> UDP.backoff_timeout_seconds(attempt) * 1_000
    end
  end

  @doc false
  @spec udp_exhausted?(non_neg_integer()) :: boolean()
  def udp_exhausted?(attempt) when is_integer(attempt), do: attempt > @udp_max_backoff_attempt

  @doc false
  @spec udp_backoff_ms_for_test(non_neg_integer()) :: pos_integer()
  def udp_backoff_ms_for_test(attempt), do: udp_backoff_ms(attempt)

  defp numwant(0), do: 0

  defp numwant(_), do: 200
end
