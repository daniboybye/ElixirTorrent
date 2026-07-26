defmodule Tracker do
  @moduledoc """
  HTTP and UDP (BEP 15) tracker announce/scrape client with multi-homed source IP selection.
  """

  require Logger

  alias __MODULE__.{Error, Response, UDP}

  @type connection_id :: <<_::64>>
  @type announce :: binary()
  @type stats :: :auto | keyword()
  @type scrape_stats :: UDP.scrape_stats()
  @type scrape_result :: %{
          seeders: non_neg_integer(),
          leechers: non_neg_integer(),
          completed: non_neg_integer()
        }

  # BEP-friendly HTTP/UDP budget at swarm target — keep-alive reuse and full BEP 15
  # retransmit ladder (15 * 2^n s, up to ~127 min) for healthy trackers.
  @timeout 5 * 60 * 1_000
  @udp_max_backoff_attempt UDP.max_backoff_attempt()
  # Under swarm target (CGNAT peer scarcity): a single dead tier-0 host must not
  # park the parallel batch for 5 min (HTTP) or minutes of UDP backoff while
  # higher tiers sit unused — fail fast and let Announce hop tiers.
  @under_target_http_timeout_ms 15_000
  @under_target_udp_max_attempts 0

  # in seconds
  @spec default_interval() :: pos_integer()
  def default_interval, do: 30 * 60

  # Fallback re-announce delay after a tracker error that carried no explicit
  # `retry_in` hint. Kept short (5 min) so transient outages — DNS blip, tracker
  # restart, brief 5xx — recover quickly instead of stalling the swarm for half
  # an hour. Trackers that want us to back off longer already say so via
  # `retry_in`, `min_interval`, or `retry_in: "never"` (permanent disable).
  @spec default_failure_interval() :: pos_integer()
  def default_failure_interval, do: 5 * 60

  @type request_opts :: [
          max_udp_attempts: 0..8,
          http_timeout_ms: pos_integer()
        ]

  @doc false
  @spec fast_fail_request_opts() :: request_opts()
  def fast_fail_request_opts do
    [
      http_timeout_ms: @under_target_http_timeout_ms,
      max_udp_attempts: @under_target_udp_max_attempts
    ]
  end

  @spec request!(binary(), Torrent.hash(), stats() | :auto, request_opts()) ::
          Response.t() | Error.t() | none()
  def request!(announce, hash, stats \\ :auto, opts \\ [])

  def request!(<<"http", _::binary>> = announce, hash, stats, opts) do
    case resolve_stats(hash, stats) do
      {:ok, {uploaded, downloaded, left, event}} ->
        do_http_request!(announce, hash, uploaded, downloaded, left, event, opts)

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

    case resolve_hosts(host) do
      {:ok, hosts} ->
        source_ips = Acceptor.primary_ips()

        responses =
          hosts
          |> Enum.filter(fn {_ip, family} -> Map.get(source_ips, family) != nil end)
          |> Enum.map(&udp_announce_on_host(&1, source_ips, port, hash, stats, opts))

        merge_http_announces(responses)

      {:error, reason} ->
        # resolve_hosts failures are DNS-class (:nxdomain / timeout / …). Dead
        # public UDP trackers are the common case — BEP 12 already hops tiers.
        # Debug only (same policy as PeerDiscovery.Announce expected failures).
        Logger.debug("UDP tracker DNS resolution failed host=#{host} reason=#{inspect(reason)}")

        %Error{reason: {:dns, host, reason}, retry_in: "never"}
    end
  end

  @spec udp_announce_on_host(
          {:inet.ip_address(), :inet | :inet6},
          map(),
          :inet.port_number(),
          Torrent.hash(),
          stats(),
          request_opts()
        ) :: Response.t() | Error.t()
  defp udp_announce_on_host({ip, family}, source_ips, port, hash, stats, opts) do
    source_ip = Map.fetch!(source_ips, family)

    case Acceptor.open_udp(family, source_ip) do
      {:ok, socket} ->
        try do
          with_connection_id(
            socket,
            ip,
            port,
            fn id -> udp_announce(socket, ip, port, id, hash, stats, family, opts) end,
            opts
          )
        after
          :gen_udp.close(socket)
        end

      :error ->
        %Error{reason: {:no_udp_socket, family}}
    end
  end

  @doc false
  @spec request_with_event!(binary(), Torrent.hash(), request_opts()) ::
          {0..3 | nil, Response.t() | Error.t() | nil}
  def request_with_event!(announce, hash, opts \\ []) do
    case resolve_stats(hash, :auto) do
      {:ok, {uploaded, downloaded, left, event}} ->
        stats = [
          uploaded: uploaded,
          downloaded: downloaded,
          left: left,
          event: event
        ]

        {event, request!(announce, hash, stats, opts)}

      :skip ->
        {nil, nil}
    end
  end

  @doc false
  @spec expected_dns_failure?(term()) :: boolean()
  def expected_dns_failure?(reason)
      when reason in [:nxdomain, :timeout, :econnrefused, :ehostunreach, :enetunreach],
      do: true

  def expected_dns_failure?({:nxdomain, _}), do: true
  def expected_dns_failure?(_), do: false

  @scrape_http_timeout_ms 15_000
  @scrape_udp_max_attempts 2

  @doc """
  BEP 48 § Scrape convention — query `{seeders, leechers, completed}` for a single
  info_hash from either an HTTP or UDP tracker announce URL.

  Returns `%{seeders: n, leechers: n, completed: n}` on success, or
  `%Tracker.Error{}` on any failure (network, tracker doesn't support scrape,
  URL not scrapeable per BEP 48, etc). Never raises. Used by
  `PeerDiscovery.Announce` to detect dead-swarm trackers cheaply (no announce
  side-effect, no numwant peers to parse) so we can skip them next announce
  cycle instead of hammering them every 30 s while under swarm target.
  """
  @spec scrape(announce(), Torrent.hash()) :: scrape_result() | Error.t()
  def scrape(<<"http", _::binary>> = announce, hash) do
    case http_scrape_url(announce) do
      {:ok, base_url} -> do_http_scrape(base_url, hash)
      :not_scrapeable -> %Error{reason: :not_scrapeable, retry_in: "never"}
    end
  end

  def scrape(<<"udp:", _::binary>> = announce, hash) do
    %URI{port: port, host: host} =
      announce
      |> URI.parse()
      |> Map.update!(:port, &if(&1, do: &1, else: 6969))

    case resolve_hosts(host) do
      {:error, reason} ->
        %Error{reason: {:dns, host, reason}, retry_in: "never"}

      {:ok, hosts} ->
        v6_ok? = Acceptor.announcable_ipv6() != []

        hosts
        |> Enum.filter(fn {_ip, family} -> family != :inet6 or v6_ok? end)
        |> Enum.sort_by(&udp_scrape_family_rank/1)
        |> udp_scrape_hosts(port, hash)
    end
  end

  def scrape(_announce, _hash),
    do: %Error{reason: :not_scrapeable, retry_in: "never"}

  @spec udp_scrape_hosts(
          [{:inet.ip_address(), :inet | :inet6}],
          :inet.port_number(),
          Torrent.hash()
        ) :: scrape_result() | Error.t()
  defp udp_scrape_hosts([], _port, _hash),
    do: %Error{reason: :no_udp_socket}

  defp udp_scrape_hosts([{ip, family} | rest], port, hash) do
    case Acceptor.open_udp(family) do
      :error ->
        udp_scrape_hosts(rest, port, hash)

      {:ok, socket} ->
        try do
          result =
            udp_scrape(socket, ip, port, [hash], max_udp_attempts: @scrape_udp_max_attempts)

          case result do
            %Error{} when rest != [] -> udp_scrape_hosts(rest, port, hash)
            %Error{} = err -> err
            %{^hash => stats} -> Map.take(stats, [:seeders, :leechers, :completed])
            _ -> %Error{reason: :scrape_no_data}
          end
        after
          :gen_udp.close(socket)
        end
    end
  end

  @spec udp_scrape_family_rank({:inet.ip_address(), :inet | :inet6}) :: 0 | 1
  defp udp_scrape_family_rank({_ip, :inet6}), do: 0
  defp udp_scrape_family_rank({_ip, :inet}), do: 1

  @spec scrape_hash_chunks(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          connection_id(),
          [Torrent.hash()],
          keyword()
        ) :: %{Torrent.hash() => scrape_stats()} | Error.t()
  defp scrape_hash_chunks(socket, ip, port, connection_id, hashes, opts) do
    hashes
    |> Enum.chunk_every(UDP.max_scrape_hashes())
    |> Enum.reduce_while(%{}, fn chunk, acc ->
      merge_udp_scrape_chunk(socket, ip, port, connection_id, chunk, opts, acc)
    end)
    |> case do
      %Error{} = error -> error
      map -> map
    end
  end

  @spec merge_udp_scrape_chunk(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          connection_id(),
          [Torrent.hash()],
          keyword(),
          map()
        ) :: {:cont, map()} | {:halt, Error.t()}
  defp merge_udp_scrape_chunk(socket, ip, port, connection_id, chunk, opts, acc) do
    case do_udp_scrape(socket, ip, port, connection_id, chunk, opts) do
      {:ok, chunk_map} -> {:cont, Map.merge(acc, chunk_map)}
      %Error{} = error -> {:halt, error}
    end
  end

  @spec do_http_scrape(binary(), Torrent.hash()) :: scrape_result() | Error.t()
  defp do_http_scrape(base_url, hash) do
    info_hash_query = URI.encode_query(%{"info_hash" => hash})
    url = append_query(base_url, info_hash_query)

    http_opts = [
      timeout: @scrape_http_timeout_ms,
      recv_timeout: @scrape_http_timeout_ms,
      hackney: [pool: false]
    ]

    try do
      case HTTPoison.get(url, [], http_opts) do
        {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
          decode_http_scrape_body(body, hash)

        {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
          decode_http_error_response(body, code)

        {:error, %HTTPoison.Error{reason: reason}} ->
          %Error{reason: reason}
      end
    rescue
      _e in [CaseClauseError] -> %Error{reason: :badarg}
    catch
      :exit, reason -> %Error{reason: reason}
      :error, :badarg -> %Error{reason: :badarg}
    end
  end

  @spec decode_http_scrape_body(binary(), Torrent.hash()) :: scrape_result() | Error.t()
  defp decode_http_scrape_body(body, hash) do
    case Bento.decode!(body) do
      %{"files" => files} when is_map(files) ->
        case Map.get(files, hash) do
          %{} = entry ->
            %{
              seeders: Map.get(entry, "complete", 0),
              leechers: Map.get(entry, "incomplete", 0),
              completed: Map.get(entry, "downloaded", 0)
            }

          _ ->
            %Error{reason: :scrape_no_data}
        end

      %{"failure reason" => reason} ->
        %Error{reason: reason}

      _ ->
        %Error{reason: :scrape_invalid_response}
    end
  rescue
    _ -> %Error{reason: :scrape_invalid_response}
  end

  @doc false
  @spec http_scrape_url(binary()) :: {:ok, binary()} | :not_scrapeable
  def http_scrape_url(announce) do
    uri = URI.parse(announce)
    path = uri.path || ""

    if Path.basename(path) == "announce" do
      new_path = String.replace_suffix(path, "announce", "scrape")
      {:ok, URI.to_string(%{uri | path: new_path})}
    else
      :not_scrapeable
    end
  end

  defp do_http_request!(announce, hash, uploaded, downloaded, left, event, opts) do
    query =
      build_http_announce_query(hash, uploaded, downloaded, left, event)
      |> URI.encode_query()

    url = append_query(announce, query)

    %{inet: ip4, inet6: ip6, inet6_all: v6_all} = Acceptor.all_global_ips()
    tracker_families = http_tracker_families(announce)
    ipv4_announce = if MapSet.member?(tracker_families, :inet), do: ip4

    v6_announces =
      if MapSet.member?(tracker_families, :inet6), do: Acceptor.announcable_ipv6(), else: []

    if ip4 || ip6 do
      Logger.info(
        "[tracker_announce] http_endpoints hash=#{Torrent.hex_encoded_hash(hash)} ipv4=#{if ip4, do: Acceptor.format_ip(ip4), else: "none"} ipv6_announce=#{Enum.map_join(v6_announces, ",", &Acceptor.format_ip/1)} ipv6_all=#{Enum.map_join(v6_all, ",", &Acceptor.format_ip/1)}"
      )
    end

    responses =
      []
      |> maybe_http_announce(url, :inet, ipv4_announce, opts)
      |> then(fn acc ->
        Enum.reduce(v6_announces, acc, fn ip6_addr, a ->
          [http_announce(url, :inet6, ip6_addr, opts) | a]
        end)
      end)

    merge_http_announces(responses)
  end

  @spec append_query(binary(), binary()) :: binary()
  defp append_query(url, encoded_query) do
    uri = URI.parse(url)

    query =
      case uri.query do
        nil -> encoded_query
        "" -> encoded_query
        existing -> existing <> "&" <> encoded_query
      end

    URI.to_string(%{uri | query: query})
  end

  @spec http_tracker_families(binary()) :: MapSet.t(:inet | :inet6)
  defp http_tracker_families(announce) do
    case URI.parse(announce).host do
      host when is_binary(host) ->
        case resolve_hosts(host) do
          {:ok, hosts} -> hosts |> Enum.map(&elem(&1, 1)) |> MapSet.new()
          {:error, _reason} -> MapSet.new([:inet, :inet6])
        end

      nil ->
        MapSet.new([:inet, :inet6])
    end
  end

  @doc false
  @spec build_http_announce_query(
          Torrent.hash(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          0..3
        ) :: map()
  def build_http_announce_query(hash, uploaded, downloaded, left, event) do
    %{
      "info_hash" => hash,
      "peer_id" => Peer.id(),
      "port" => Acceptor.port(),
      "compact" => 1,
      "uploaded" => uploaded,
      "downloaded" => downloaded,
      "left" => left,
      "numwant" => numwant(left),
      "key" => Acceptor.key()
    }
    |> maybe_put_announce_param("event", Torrent.event_to_string(event))
  end

  @spec maybe_put_announce_param(map(), String.t(), binary() | nil) :: map()
  defp maybe_put_announce_param(query, _key, nil), do: query

  defp maybe_put_announce_param(query, key, value) when is_binary(value),
    do: Map.put(query, key, value)

  @spec with_connection_id(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          (connection_id() -> term()),
          request_opts()
        ) :: term()
  defp with_connection_id(socket, ip, port, fun, opts) when is_function(fun, 1) do
    case fetch_connection_id(socket, ip, port, opts) do
      {:ok, id} ->
        retry_on_expired_connection_id(socket, ip, port, fun, fun.(id), opts)

      %Error{} = error ->
        error
    end
  end

  # At swarm target, reuse cached connection_ids via ConnectionIds (45 s cap).
  # Under target, `fast_fail_request_opts/0` lowers `max_udp_attempts` so we
  # connect inline with one BEP 15 recv (~15 s) instead of waiting on the
  # shared ConnectionIds queue and full retransmit ladder.
  @spec fetch_connection_id(port(), :inet.ip_address(), :inet.port_number(), request_opts()) ::
          {:ok, connection_id()} | Error.t()
  defp fetch_connection_id(socket, ip, port, opts) do
    max_attempts = Keyword.get(opts, :max_udp_attempts, @udp_max_backoff_attempt)

    if max_attempts < @udp_max_backoff_attempt do
      case udp_connect(socket, ip, port, opts) do
        <<_::64>> = id -> {:ok, id}
        %Error{} = error -> error
      end
    else
      case safe_connection_id(socket, ip, port) do
        {:ok, id} -> {:ok, id}
        %Error{} = error -> error
        :error -> %Error{reason: :connection_id_unavailable}
      end
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
          term(),
          request_opts()
        ) :: term()
  defp retry_on_expired_connection_id(_socket, _ip, _port, _fun, result, _opts)
       when not is_struct(result, Error),
       do: result

  defp retry_on_expired_connection_id(socket, ip, port, fun, %Error{reason: reason} = error, opts) do
    if connection_id_expired?(reason) do
      :ok = PeerDiscovery.invalidate_connection_id(socket, ip, port)

      case fetch_connection_id(socket, ip, port, opts) do
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
          case decode_tracker_body(body, url, family, ip, headers, http_opts, 0) do
            %Response{peers: peers} = response ->
              v6 = Enum.count(peers, &ipv6_peer?/1)

              Logger.info(
                "[tracker_announce] http family=#{family} local=#{Acceptor.format_ip(ip)} peers=#{length(peers)} ipv6_peers=#{v6}"
              )

              response

            %Error{} = error ->
              error
          end

        {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
          decode_http_error_response(body, code)

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

  # BEP 7 requires the tracker connection's source to be the address being
  # announced. The family option must accompany an IPv6 bind tuple; without it
  # Hackney's TCP connect path treats the tuple as an IPv4 bind and raises badarg.
  #
  # `pool: false` isolates each announce. Hackney 4's named pool can terminate
  # when a request owner exits while its connection process is starting; one
  # torrent's normal shutdown must not break HTTP discovery for every torrent.
  @spec http_hackney_opts(:inet | :inet6, :inet.ip_address()) :: keyword()
  defp http_hackney_opts(:inet, ip),
    do: [pool: false, connect_options: [{:ip, ip}]]

  defp http_hackney_opts(:inet6, ip),
    do: [pool: false, connect_options: [:inet6, {:ip, ip}]]

  @doc false
  @spec http_hackney_opts_for_test(:inet | :inet6, :inet.ip_address()) :: keyword()
  def http_hackney_opts_for_test(family, ip), do: http_hackney_opts(family, ip)

  @spec badarg_clause?(term()) :: boolean()
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

            {:ok, %HTTPoison.Response{status_code: code, body: body2}} ->
              decode_http_error_response(body2, code)

            {:error, %HTTPoison.Error{reason: reason}} ->
              %Error{reason: reason}
          end

        _ ->
          %Error{reason: :non_bencoded_response, retry_in: "never"}
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
    case Regex.run(~r/window\.location\.href\s*=\s*"([^"]+)"/, body, capture: :all_but_first) do
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

  @doc false
  @spec extract_js_redirect_for_test(binary()) :: {:ok, binary()} | :error
  def extract_js_redirect_for_test(body), do: extract_js_redirect(body)

  @doc false
  @spec absolute_redirect_for_test(binary(), binary()) :: binary()
  def absolute_redirect_for_test(base_url, redirect), do: absolute_redirect(base_url, redirect)

  @doc false
  @spec decode_http_response_for_test(map()) :: Response.t() | Error.t()
  def decode_http_response_for_test(map) when is_map(map), do: decode_http_response(map)

  @doc false
  @spec merge_http_announces_for_test([Response.t() | Error.t()]) :: Response.t() | Error.t()
  def merge_http_announces_for_test(list) when is_list(list), do: merge_http_announces(list)

  @doc false
  @spec decode_http_scrape_body_for_test(binary(), Torrent.hash()) ::
          scrape_result() | Error.t()
  def decode_http_scrape_body_for_test(body, hash),
    do: decode_http_scrape_body(body, hash)

  @spec decode_http_response(map()) :: Response.t() | Error.t()
  defp decode_http_response(%{"failure reason" => reason} = map) do
    %Error{
      reason: reason,
      # Tracker.Error.retry_in is an internal seconds value. BEP 31's wire
      # value is minutes, so normalize it at the HTTP decode boundary; UDP and
      # connection-id errors already populate this field in seconds.
      retry_in: bep31_retry_interval_seconds(Map.get(map, "retry in"))
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
      external_ip: valid_external_ip(Map.get(map, "external ip")),
      peers: peers_v4 ++ peers_v6
    }
  end

  @spec decode_http_error_response(binary(), non_neg_integer()) :: Error.t()
  defp decode_http_error_response(body, status_code) do
    case body |> Bento.decode!() |> decode_http_response() do
      %Error{} = error -> error
      _response -> %Error{reason: {:http_status, status_code}}
    end
  rescue
    _ -> %Error{reason: {:http_status, status_code}}
  end

  @spec bep31_retry_interval_seconds(term()) :: non_neg_integer() | binary() | nil
  defp bep31_retry_interval_seconds(value) when value in ["never", :never], do: "never"

  defp bep31_retry_interval_seconds(minutes) when is_integer(minutes) and minutes >= 0,
    do: minutes * 60

  defp bep31_retry_interval_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {minutes, ""} when minutes >= 0 -> minutes * 60
      _ -> nil
    end
  end

  defp bep31_retry_interval_seconds(_), do: nil

  defp valid_external_ip(ip) when is_binary(ip) and byte_size(ip) in [4, 16], do: ip
  defp valid_external_ip(_ip), do: nil

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
      min_interval: merge_min_interval(a.min_interval, b.min_interval),
      complete: max(a.complete, b.complete),
      incomplete: max(a.incomplete, b.incomplete),
      external_ip: a.external_ip || b.external_ip,
      peers: peers
    }
  end

  @spec merge_min_interval(non_neg_integer() | nil, non_neg_integer() | nil) ::
          non_neg_integer() | nil
  defp merge_min_interval(nil, nil), do: nil
  defp merge_min_interval(nil, value), do: value
  defp merge_min_interval(value, nil), do: value
  defp merge_min_interval(left, right), do: max(left, right)

  @doc """
  BEP 15 § Connect — obtain a connection_id with exponential backoff retransmission.

  Sends action=0 with magic `protocol_id`, validates action/transaction_id on response,
  and returns `%Tracker.Error{}` (including `reason: :timeout`) instead of raising.
  """
  @spec udp_connect(port(), :inet.ip_address(), :inet.port_number(), request_opts()) ::
          connection_id() | Error.t()
  def udp_connect(socket, ip, port, opts \\ []) do
    transaction_id = generate_transaction_id()
    packet = UDP.encode_connect(transaction_id)
    max_attempts = Keyword.get(opts, :max_udp_attempts, @udp_max_backoff_attempt)

    do_udp_request(socket, ip, port, packet, transaction_id,
      expected: :connect,
      attempt: 0,
      max_udp_attempts: max_attempts
    )
  end

  @doc """
  BEP 15 § Scrape — query seeders/completed/leechers for up to 74 info_hashes per request.

  Multiple hashes are chunked automatically. Returns a map of hash => stats or `%Tracker.Error{}`.
  """
  @spec udp_scrape(port(), :inet.ip_address(), :inet.port_number(), [Torrent.hash()], keyword()) ::
          %{Torrent.hash() => scrape_stats()} | Error.t()
  def udp_scrape(socket, ip, port, hashes, opts \\ [])

  def udp_scrape(_socket, _ip, _port, [], _opts), do: %{}

  def udp_scrape(socket, ip, port, hashes, opts) do
    with_connection_id(
      socket,
      ip,
      port,
      fn connection_id ->
        scrape_hash_chunks(socket, ip, port, connection_id, hashes, opts)
      end,
      opts
    )
  end

  @spec do_udp_scrape(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          connection_id(),
          [Torrent.hash()],
          keyword()
        ) :: {:ok, %{Torrent.hash() => scrape_stats()}} | Error.t()
  defp do_udp_scrape(socket, ip, port, connection_id, hashes, opts) do
    transaction_id = generate_transaction_id()
    packet = UDP.encode_scrape(connection_id, transaction_id, hashes)
    max_attempts = Keyword.get(opts, :max_udp_attempts, @udp_max_backoff_attempt)

    case do_udp_request(socket, ip, port, packet, transaction_id,
           expected: :scrape,
           hash_count: length(hashes),
           attempt: 0,
           max_udp_attempts: max_attempts
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
    packet = encode_udp_announce(connection_id, transaction_id, hash, announce_stats, family)
    max_attempts = Keyword.get(opts, :max_udp_attempts, @udp_max_backoff_attempt)

    request_opts =
      [
        expected: :announce,
        family: family,
        attempt: 0,
        max_udp_attempts: max_attempts
      ]
      |> maybe_put_announce_retry_packet(%{
        socket: socket,
        ip: ip,
        port: port,
        transaction_id: transaction_id,
        hash: hash,
        announce_stats: announce_stats,
        family: family,
        opts: opts
      })

    case do_udp_request(socket, ip, port, packet, transaction_id, request_opts) do
      %Response{peers: peers} = response ->
        v6 = Enum.count(peers, &ipv6_peer?/1)

        Logger.info(
          "[tracker_announce] udp family=#{family} tracker=#{Acceptor.format_ip(ip)}:#{port} peers=#{length(peers)} ipv6_peers=#{v6}"
        )

        response

      %Error{} = error ->
        error

      {:error, reason} ->
        %Error{reason: reason}

      other ->
        %Error{reason: other}
    end
  end

  # Only the full announce ladder can outlive BEP 15's one-minute connection-id
  # validity window. Before each of its retries, ask the cache again: it returns
  # the same id while valid and performs a fresh connect after expiry.
  defp maybe_put_announce_retry_packet(request_opts, ctx) do
    if Keyword.fetch!(request_opts, :max_udp_attempts) == @udp_max_backoff_attempt do
      retry_packet = fn -> build_announce_retry_packet(ctx) end
      Keyword.put(request_opts, :retry_packet, retry_packet)
    else
      request_opts
    end
  end

  @spec build_announce_retry_packet(map()) :: {:ok, iodata()} | Error.t()
  defp build_announce_retry_packet(%{
         socket: socket,
         ip: ip,
         port: port,
         transaction_id: transaction_id,
         hash: hash,
         announce_stats: announce_stats,
         family: family,
         opts: opts
       }) do
    case fetch_connection_id(socket, ip, port, opts) do
      {:ok, id} ->
        {:ok, encode_udp_announce(id, transaction_id, hash, announce_stats, family)}

      %Error{} = error ->
        error
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
      # The socket can be closed by a racing announce for the same tracker.
      case :gen_udp.send(socket, ip, port, packet) do
        :ok ->
          do_udp_request_recv(
            socket,
            ip,
            port,
            packet,
            transaction_id,
            opts,
            attempt,
            max_attempts
          )

        {:error, reason} ->
          %Error{reason: reason}
      end
    end
  end

  defp do_udp_request_recv(socket, ip, port, packet, transaction_id, opts, attempt, max_attempts) do
    timeout_ms = udp_backoff_ms(attempt)

    case udp_recv_until(socket, ip, port, transaction_id, timeout_ms, opts) do
      {:ok, result} ->
        result

      {:error, :timeout} ->
        retry_udp_request(socket, ip, port, packet, transaction_id, opts, attempt, max_attempts)

      {:error, reason} when is_binary(reason) ->
        %Error{reason: reason}

      {:error, reason} ->
        %Error{reason: reason}
    end
  end

  defp retry_udp_request(
         socket,
         ip,
         port,
         packet,
         transaction_id,
         opts,
         attempt,
         max_attempts
       ) do
    next_attempt = attempt + 1
    next_opts = Keyword.merge(opts, attempt: next_attempt, max_udp_attempts: max_attempts)

    if next_attempt > max_attempts do
      %Error{reason: :timeout}
    else
      retry_with_next_packet(socket, ip, port, packet, transaction_id, opts, next_opts)
    end
  end

  @spec retry_with_next_packet(
          port(),
          :inet.ip_address(),
          :inet.port_number(),
          iodata(),
          <<_::32>>,
          keyword(),
          keyword()
        ) :: connection_id() | Response.t() | [scrape_stats()] | Error.t()
  defp retry_with_next_packet(socket, ip, port, packet, transaction_id, opts, next_opts) do
    case Keyword.get(opts, :retry_packet) do
      retry_packet when is_function(retry_packet, 0) ->
        case retry_packet.() do
          {:ok, refreshed_packet} ->
            do_udp_request(socket, ip, port, refreshed_packet, transaction_id, next_opts)

          %Error{} = error ->
            error
        end

      nil ->
        do_udp_request(socket, ip, port, packet, transaction_id, next_opts)
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
      {:ok, {from_ip, from_port, body}} ->
        # BEP 15: responses are matched by transaction id, not source address —
        # multihomed trackers may answer from another IP. Undecodable datagrams
        # only fail the request when they come from the tracker itself; stray
        # traffic (scanners, stale peers) is dropped and the wait continues.
        case UDP.classify_response(body, transaction_id, opts) do
          :ignore ->
            recv_loop(socket, ip, port, transaction_id, deadline_ms, opts)

          {:ok, result} ->
            {:ok, result}

          {:error, _reason} when from_ip != ip or from_port != port ->
            recv_loop(socket, ip, port, transaction_id, deadline_ms, opts)

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
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), 0..3},
          :inet | :inet6
        ) :: iodata()
  defp encode_udp_announce(
         connection_id,
         transaction_id,
         hash,
         {uploaded, downloaded, left, event},
         family
       ) do
    ip_field = udp_announce_ip_field(family)

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

  # BEP 15 § Announce — IPv6 clients set ip_field to 0; tracker learns address from packet source.
  @spec udp_announce_ip_field(:inet | :inet6) :: <<_::32>>
  defp udp_announce_ip_field(:inet6), do: <<0::32>>

  defp udp_announce_ip_field(:inet) do
    case Acceptor.ipv4_binary() do
      <<a, b, c, d>> -> <<a, b, c, d>>
      _ -> <<0::32>>
    end
  end

  @doc false
  @spec encode_udp_announce_for_test(
          connection_id(),
          <<_::32>>,
          Torrent.hash(),
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), 0..3},
          :inet | :inet6
        ) :: iodata()
  def encode_udp_announce_for_test(connection_id, transaction_id, hash, stats, family) do
    encode_udp_announce(connection_id, transaction_id, hash, stats, family)
  end

  # HTTP trackers typically return:
  # - "peers": compact IPv4 peers (6-byte entries) when compact=1 (BEP 23)
  # - "peers6": compact IPv6 peers (18-byte entries) (BEP 7, widely deployed)
  @spec to_peers_v4(binary() | list() | any()) :: list(Peer.t())
  defp to_peers_v4(bin) when is_binary(bin), do: UDP.parse_compact_peers(bin, :inet)
  defp to_peers_v4(list) when is_list(list), do: parse_peer_dicts(list)
  defp to_peers_v4(_), do: []

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
    # Dictionary-model hostnames are deliberately not resolved here. Tracker
    # responses are untrusted and resolving an unbounded list would put
    # synchronous DNS work on the announce decode path.
    ip
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> :error
    end
  end

  @doc false
  @spec resolve_hosts(binary()) ::
          {:ok, [{:inet.ip_address(), :inet | :inet6}]} | {:error, term()}
  def resolve_hosts(host) do
    char_host = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(char_host, :inet) do
        {:ok, ips} -> Enum.map(ips, &{&1, :inet})
        {:error, _} -> []
      end

    v6 =
      case :inet.getaddrs(char_host, :inet6) do
        {:ok, ips} -> Enum.map(ips, &{&1, :inet6})
        {:error, _} -> []
      end

    case v4 ++ v6 do
      [] ->
        {:error, :nxdomain}

      hosts ->
        {:ok, hosts}
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
  defp generate_transaction_id,
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

  @spec ipv6_peer?(Peer.t()) :: boolean()
  defp ipv6_peer?(%Peer{ip: ip}), do: tuple_size(ip) == 8
  defp ipv6_peer?(_), do: false
end
