defmodule Torrent.WebSeed do
  @moduledoc """
  BEP 19 GetRight-style HTTP/URL seeding.

  Optional per-torrent GenServer that pulls missing pieces from HTTP URLs
  advertised in the .torrent's top-level `url-list` key. Runs in parallel
  with the regular peer swarm: when a torrent has few peers (or none),
  webseeds keep bytes flowing; when the swarm is healthy, webseeds are
  still useful for pieces no peer has.

  Design notes:

    * Ignore itself out of the tree when the metadata has no `url-list`
      (magnet-only torrents; .torrents without the extension). The child
      spec returns `:ignore` so the Torrent supervisor doesn't restart it.
    * Never race a `Torrent.Downloads.Piece` worker: before claiming a
      piece the webseed checks `Downloads.piece_active?/2` and skips.
    * On success, writes bytes via `Torrent.FileHandle.write/4`, then runs
      `FileHandle.check?/3` — which performs the torrent's hash verify and calls
      `Torrent.Model.downloaded_piece/2` + `PiecesStatistic.set(:complete)`
      inline, exactly the same code path a normal peer download hits after
      the last subpiece arrives. On verify-ok we also call `Swarm.have/2`
      so connected peers learn we can serve the piece.
    * URL selection is a simple round-robin over URLs that aren't in
      per-URL backoff. Transient failures escalate the backoff exponentially
      per URL; first success resets it. A URL that serves bytes failing piece
      hash verification is disabled for the rest of the session.

  URL resolution per BEP 19:

    * Single-file torrent: URL is either the direct file URL, or (if it
      ends with `/`) a directory into which the `info["name"]` file lives.
    * Multi-file torrent: URL is a directory root; per-file URL is
      `url/name/path0/path1/…` (URL-encoded path components; `name` is the
      torrent-root directory name).
  """

  use GenServer
  use Via

  require Logger

  alias Torrent.{Bitfield, Downloads, FileHandle, Model, Swarm}

  # Bound on concurrent piece fetches — webseeds are a background source,
  # not a stampede. Each in-flight piece opens one direct hackney connection
  # (Range GET), so this also caps HTTP connection pressure on the seed.
  @max_parallel 2
  @tick_ms 5_000
  @initial_delay_ms 8_000
  @error_backoff_base_ms 30_000
  @error_backoff_max_ms 15 * 60_000
  @request_timeout_ms 60_000
  @recv_timeout_ms 60_000

  defstruct [
    :hash,
    :info,
    :piece_length,
    :last_index,
    :last_piece_length,
    :multi_file?,
    urls: [],
    url_state: %{},
    disabled_urls: MapSet.new(),
    tasks: %{}
  ]

  @type url :: String.t()

  @spec child_spec(Torrent.hash()) :: Supervisor.child_spec()
  def child_spec(hash) do
    %{
      id: __MODULE__,
      restart: :transient,
      start: {__MODULE__, :start_link, [hash]}
    }
  end

  @spec start_link(Torrent.hash()) :: GenServer.on_start()
  def start_link(hash) do
    GenServer.start_link(__MODULE__, hash, name: via(hash))
  end

  @impl true
  def init(hash) do
    case load_config(hash) do
      {:ok, state} ->
        Logger.info(
          "[webseed] enabled hash=#{Torrent.hex_encoded_hash(hash)} urls=#{length(state.urls)}"
        )

        Process.send_after(self(), :tick, @initial_delay_ms)
        {:ok, state}

      :none ->
        # Silent: no url-list in metadata is the common case (magnets, older
        # .torrents). Nothing to supervise; return :ignore so the supervisor
        # doesn't restart-loop us. Torrent.init treats :ignore normally.
        :ignore
    end
  end

  @impl true
  def handle_info(:tick, %__MODULE__{} = state) do
    state = maybe_pick(state)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, state}
  end

  # A per-piece fetch process reports its verdict tagged by its pid, and we
  # demonitor by the ref we stashed alongside. The DOWN handler is the
  # safety net for unclean exits (network stack throwing, hackney crashing)
  # so a dead task never leaks its `tasks` slot.
  def handle_info({:webseed_result, pid, _index, url, :ok}, %__MODULE__{tasks: tasks} = state) do
    tasks =
      case Map.pop(tasks, pid) do
        {{ref, _index, _url}, tasks} ->
          Process.demonitor(ref, [:flush])
          tasks

        {nil, tasks} ->
          tasks
      end

    {:noreply,
     %{state | tasks: tasks, url_state: reset_url(state.url_state, url)} |> maybe_pick()}
  end

  def handle_info(
        {:webseed_result, pid, index, url, {:error, reason}},
        %__MODULE__{tasks: tasks} = state
      ) do
    tasks =
      case Map.pop(tasks, pid) do
        {{ref, _index, _url}, tasks} ->
          Process.demonitor(ref, [:flush])
          tasks

        {nil, tasks} ->
          tasks
      end

    Logger.debug(
      "[webseed] fail hash=#{Torrent.hex_encoded_hash(state.hash)} index=#{index} url=#{url} reason=#{inspect(reason)}"
    )

    state =
      case reason do
        :hash_mismatch ->
          %{state | disabled_urls: MapSet.put(state.disabled_urls, url)}

        _ ->
          %{state | url_state: penalise_url(state.url_state, url)}
      end

    {:noreply, %{state | tasks: tasks} |> maybe_pick()}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %__MODULE__{tasks: tasks} = state) do
    case Map.pop(tasks, pid) do
      {nil, _} ->
        {:noreply, state}

      {{_ref, index, url}, tasks} ->
        Logger.debug(
          "[webseed] task_down hash=#{Torrent.hex_encoded_hash(state.hash)} index=#{index} url=#{url} reason=#{inspect(reason)}"
        )

        {:noreply,
         %{state | tasks: tasks, url_state: penalise_url(state.url_state, url)}
         |> maybe_pick()}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- picking / scheduling ---

  defp maybe_pick(%__MODULE__{} = state) do
    cond do
      Model.downloaded?(state.hash) ->
        state

      map_size(state.tasks) >= @max_parallel ->
        state

      true ->
        maybe_pick_from_url(state)
    end
  end

  defp maybe_pick_from_url(state) do
    with url when not is_nil(url) <- eligible_url(state),
         index when not is_nil(index) <- pick_index(state) do
      spawn_fetch(state, index, url)
    else
      _ -> state
    end
  end

  defp eligible_url(%__MODULE__{urls: urls, url_state: st, disabled_urls: disabled_urls}) do
    now = System.monotonic_time(:millisecond)

    candidates =
      Enum.filter(urls, fn url ->
        not MapSet.member?(disabled_urls, url) and
          case Map.get(st, url) do
            nil -> true
            %{next_ok_at_ms: t} -> t <= now
          end
      end)

    case candidates do
      [] -> nil
      list -> Enum.random(list)
    end
  end

  # Pick the lowest-index missing piece we're not already fetching and no
  # Downloads.Piece worker is actively pulling. Simple and predictable — the
  # peer swarm already handles rarest-first; webseeds fill in.
  defp pick_index(%__MODULE__{hash: hash, last_index: last_index, tasks: tasks}) do
    bitfield = Model.get(hash, :bitfield)
    in_flight = tasks |> Map.values() |> MapSet.new(fn {_ref, index, _url} -> index end)

    Enum.find(0..last_index, fn index ->
      not Bitfield.have?(bitfield, index) and
        not MapSet.member?(in_flight, index) and
        not Downloads.piece_active?(hash, index)
    end)
  end

  defp spawn_fetch(%__MODULE__{} = state, index, url) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            do_fetch(state, index, url)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:webseed_result, self(), index, url, result})
      end)

    tasks = Map.put(state.tasks, pid, {ref, index, url})
    %{state | tasks: tasks}
  end

  # --- per-piece fetch ---

  defp do_fetch(%__MODULE__{} = state, index, url) do
    piece_len = piece_length(state, index)
    begin_byte = index * state.piece_length
    end_byte = begin_byte + piece_len - 1

    with {:ok, iodata} <- fetch_range(state, url, begin_byte, end_byte, piece_len),
         :ok <- write_piece(state.hash, index, iodata),
         true <- FileHandle.check?(state.hash, index) do
      Swarm.have(state.hash, index)

      Logger.debug(
        "[webseed] ok hash=#{Torrent.hex_encoded_hash(state.hash)} index=#{index} bytes=#{piece_len} url=#{url}"
      )

      :ok
    else
      false ->
        # Wrote piece but hash didn't match — FileHandle.check?/3 already
        # called Model.hash_check_failure/2, resetting the bitfield bit and
        # the pieces_statistic slot. This mirror is unsafe for this torrent,
        # so the GenServer disables it for the rest of the current session.
        Logger.warning(
          "[webseed] hash_mismatch hash=#{Torrent.hex_encoded_hash(state.hash)} index=#{index} url=#{url}"
        )

        {:error, :hash_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Map the byte range [begin_byte, end_byte] onto the physical files and
  # issue one Range GET per file segment. For a single-file torrent this is
  # a single request; for a multi-file torrent this crosses at most
  # (files_touched) segments per piece — normally 1, sometimes 2.
  defp fetch_range(%__MODULE__{info: info} = state, url, begin_byte, end_byte, expected_len) do
    segments = span_files(info, begin_byte, end_byte)

    result = do_fetch_segments(state, url, segments, [])

    case result do
      {:ok, iodata} ->
        actual_len = IO.iodata_length(iodata)

        if actual_len == expected_len do
          {:ok, iodata}
        else
          {:error, {:short_body, actual_len, expected_len}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp do_fetch_segments(_state, _url, [], acc), do: {:ok, Enum.reverse(acc)}

  defp do_fetch_segments(
         %__MODULE__{} = state,
         url,
         [%{path: path, offset: offset, length: length} | rest],
         acc
       ) do
    file_url = file_url(state, url, path)

    range_hdr = "bytes=#{offset}-#{offset + length - 1}"

    http_opts = [
      timeout: @request_timeout_ms,
      recv_timeout: @recv_timeout_ms,
      follow_redirect: true,
      max_redirect: 3,
      hackney: [pool: false]
    ]

    case HTTPoison.get(file_url, [{"Range", range_hdr}, {"Accept", "*/*"}], http_opts) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in [200, 206] ->
        if byte_size(body) == length do
          do_fetch_segments(state, url, rest, [body | acc])
        else
          {:error, {:segment_short, byte_size(body), length}}
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, {:http_status, code}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Piece bytes may span multiple files. Walk `info["files"]` (or the single
  # `info["length"]`) cumulatively and cut out the segments that touch
  # [begin_byte, end_byte].
  @doc false
  @spec span_files(map(), non_neg_integer(), non_neg_integer()) :: [
          %{path: [String.t()], offset: non_neg_integer(), length: pos_integer()}
        ]
  def span_files(%{"length" => length, "name" => name}, begin_byte, end_byte) do
    seg_end = min(end_byte, length - 1)

    if begin_byte > seg_end do
      []
    else
      [%{path: [name], offset: begin_byte, length: seg_end - begin_byte + 1}]
    end
  end

  def span_files(%{"files" => files}, begin_byte, end_byte) do
    {segments, _} =
      Enum.reduce(files, {[], 0}, fn %{"length" => file_len, "path" => path}, {acc, cursor} ->
        file_begin = cursor
        file_end = cursor + file_len - 1
        cursor = cursor + file_len

        cond do
          file_end < begin_byte ->
            {acc, cursor}

          file_begin > end_byte ->
            {acc, cursor}

          true ->
            overlap_begin = max(begin_byte, file_begin)
            overlap_end = min(end_byte, file_end)
            offset = overlap_begin - file_begin
            length = overlap_end - overlap_begin + 1
            {[%{path: path, offset: offset, length: length} | acc], cursor}
        end
      end)

    Enum.reverse(segments)
  end

  # Compute the per-file URL. Path segments are URL-encoded; slashes join.
  # For single-file torrents, either the URL points directly at the file or
  # (if it ends with /) it's a directory that contains the file. For
  # multi-file torrents, URL is a directory root; prepend `info["name"]` and
  # append the per-file path components.
  defp file_url(%__MODULE__{multi_file?: false, info: info}, url, [name]) do
    if String.ends_with?(url, "/") do
      url <> encode_segment(name)
    else
      # BEP 19: URL is the direct file URL (ignore the info name).
      _ = info
      url
    end
  end

  defp file_url(%__MODULE__{multi_file?: true, info: info}, url, path) do
    prefix = if String.ends_with?(url, "/"), do: url, else: url <> "/"

    name = info["name"]
    tail = Enum.map_join([name | path], "/", &encode_segment/1)
    prefix <> tail
  end

  defp encode_segment(seg) do
    seg
    |> to_string()
    |> URI.encode(&URI.char_unreserved?/1)
  end

  # Write the assembled piece bytes to disk. We chunk to piece-block size to
  # cooperate with FileHandle.write's cast semantics and to avoid oversized
  # single messages, though for typical piece sizes (256KiB–4MiB) a single
  # write is fine too.
  defp write_piece(hash, index, iodata) do
    bin = IO.iodata_to_binary(iodata)
    FileHandle.write(hash, index, 0, bin)
    :ok
  end

  defp piece_length(%__MODULE__{last_index: li, last_piece_length: lpl}, index)
       when index == li,
       do: lpl

  defp piece_length(%__MODULE__{piece_length: pl}, _index), do: pl

  # --- URL state ---

  defp reset_url(url_state, url), do: Map.delete(url_state, url)

  defp penalise_url(url_state, url) do
    now = System.monotonic_time(:millisecond)

    Map.update(url_state, url, %{failures: 1, next_ok_at_ms: now + @error_backoff_base_ms}, fn %{
                                                                                                 failures:
                                                                                                   n
                                                                                               } ->
      failures = n + 1

      delay =
        min(@error_backoff_base_ms * Integer.pow(2, min(failures - 1, 6)), @error_backoff_max_ms)

      %{failures: failures, next_ok_at_ms: now + delay}
    end)
  end

  # --- config load ---

  @spec load_config(Torrent.hash()) :: {:ok, %__MODULE__{}} | :none
  defp load_config(hash) do
    with %Torrent{
           kind: kind,
           metadata: meta,
           last_index: last_index,
           last_piece_length: lpl
         } <-
           safe_model_get(hash),
         # BEP 52 aligns every file independently; the BEP 19 flat-range mapper
         # must not request alignment gaps as HTTP file bytes.
         false <- kind == :v2,
         urls when is_list(urls) and urls != [] <- parse_url_list(meta) do
      info = meta["info"] || %{}

      state = %__MODULE__{
        hash: hash,
        info: info,
        piece_length: info["piece length"],
        last_index: last_index,
        last_piece_length: lpl,
        multi_file?: Map.has_key?(info, "files"),
        urls: urls
      }

      {:ok, state}
    else
      _ -> :none
    end
  end

  defp safe_model_get(hash) do
    Model.get(hash)
  catch
    :exit, _ -> nil
  end

  @doc false
  @spec parse_url_list(map()) :: [String.t()]
  def parse_url_list(meta) when is_map(meta) do
    case Map.get(meta, "url-list") do
      url when is_binary(url) and byte_size(url) > 0 -> normalise_urls([url])
      urls when is_list(urls) -> normalise_urls(urls)
      _ -> []
    end
  end

  def parse_url_list(_), do: []

  defp normalise_urls(list) do
    list
    |> Enum.flat_map(fn
      s when is_binary(s) -> [s]
      _ -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_http_url?/1)
    |> Enum.uniq()
  end

  defp valid_http_url?("http://" <> _), do: true
  defp valid_http_url?("https://" <> _), do: true
  defp valid_http_url?(_), do: false
end
