defmodule Peer.UtPex do
  @moduledoc """
  BEP 11 Peer Exchange (`ut_pex`) — decode, encode, ingest, and broadcast.

  Wire format follows libtorrent / webtorrent: a bencoded dictionary with compact
  peer blobs in `added`, `added6`, `dropped`, and `dropped6` (optional `*.f` flags).
  """

  alias Acceptor.Connection.Handshakes
  alias Peer.LTEP.Session
  alias Peer.UtPex.{EncodeReport, Entry, Filter}
  alias Tracker.UDP

  @extension_name "ut_pex"

  # BEP 11 / libtorrent per-peer flag bits in `added.f` / `added6.f` (one byte each):
  @flag_encrypted 0x01
  @flag_seed 0x02
  @flag_utp 0x04
  @flag_holepunch 0x08
  @flag_outgoing 0x10

  @max_non_initial_added 50
  @max_non_initial_dropped 50
  # Defensive bound on first (initial) snapshots — exempt from the 50-cap rule.
  @max_initial_added 200
  @max_inbound_payload_bytes 16_384
  @max_inbound_offer 50

  @compact_keys ~w(added added6 dropped dropped6)

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}
  @type entry_input :: endpoint() | Entry.t()

  @doc false
  @spec extension_name() :: String.t()
  def extension_name, do: @extension_name

  @doc false
  @spec flag_encrypted() :: byte()
  def flag_encrypted, do: @flag_encrypted

  @doc false
  @spec flag_seed() :: byte()
  def flag_seed, do: @flag_seed

  @doc false
  @spec flag_utp() :: byte()
  def flag_utp, do: @flag_utp

  @doc false
  @spec flag_holepunch() :: byte()
  def flag_holepunch, do: @flag_holepunch

  @doc false
  @spec flag_outgoing() :: byte()
  def flag_outgoing, do: @flag_outgoing

  @doc false
  @spec allowed?(Torrent.hash()) :: boolean()
  def allowed?(hash) do
    Torrent.get(hash, :private?) != true
  catch
    :exit, _ -> true
  end

  @doc """
  Builds `%Entry{}` values for every connected peer eligible for PEX advertisement.

  Item 4 reuses this for per-connection initial snapshots and announce ticks.
  """
  @spec snapshot_entries(Torrent.hash(), keyword()) :: [Entry.t()]
  def snapshot_entries(hash, opts \\ []) do
    exclude_key = Keyword.get(opts, :exclude_key)

    hash
    |> Torrent.Swarm.peer_supervisors()
    |> Enum.flat_map(&pex_entry_from_supervisor(&1, exclude_key))
    |> Enum.uniq_by(&Entry.endpoint/1)
  end

  defp pex_entry_from_supervisor(pid, exclude_key) do
    case Peer.get_key(pid) do
      ^exclude_key when not is_nil(exclude_key) ->
        []

      key when is_tuple(key) ->
        case Peer.Controller.pex_entry(key) do
          {:ok, entry} -> [entry]
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  Snapshot map keyed by endpoint — preserves full `%Entry{}` through announce diffs.
  """
  @spec snapshot_map(Torrent.hash(), keyword()) :: %{endpoint() => Entry.t()}
  def snapshot_map(hash, opts \\ []) do
    hash
    |> snapshot_entries(opts)
    |> Map.new(&{Entry.endpoint(&1), &1})
  end

  @doc """
  Decodes an inbound ut_pex payload and dials any new connectable peers.

  BEP 11 seed-flagged peers (`added.f` bit `@flag_seed`) are offered for dial before
  non-seeds so we prefer seeders when peer slots are scarce (CGNAT outbound dials).
  """
  @spec ingest(Torrent.hash(), binary(), keyword()) :: {:ok, [Peer.t()], [Peer.t()]} | :error
  def ingest(hash, payload, opts \\ []) when is_binary(payload) do
    result = if allowed?(hash), do: decode(payload, opts), else: :error

    case result do
      {:ok, added, dropped} ->
        ingest_decoded_peers(hash, added, dropped, opts)

      :error ->
        :error
    end
  end

  defp ingest_decoded_peers(hash, added, dropped, opts) do
    pex_source = Keyword.get(opts, :pex_source)
    filtered_added = Filter.filter_peers(added, hash)
    filtered_dropped = Filter.filter_peers(dropped, hash)

    connectable =
      filtered_added
      |> prioritize_seed_peers()
      |> Enum.filter(&Handshakes.connectable_peer?/1)

    peers = ingest_connectable_peers(connectable, pex_source)
    log_ingest_peers(hash, peers)
    ingest_apply_peers(hash, peers, filtered_dropped, pex_source)
    {:ok, filtered_added, filtered_dropped}
  end

  defp ingest_connectable_peers(connectable, pex_source) do
    if pex_source?(pex_source) do
      connectable
    else
      Enum.take(connectable, @max_inbound_offer)
    end
  end

  defp log_ingest_peers(hash, peers) do
    if peers != [] do
      require Logger

      seed_count = Enum.count(peers, &(&1.seed == true))

      Logger.info(
        "[ut_pex] ingest hash=#{Torrent.hex_encoded_hash(hash)} added=#{length(peers)} seeds=#{seed_count}"
      )
    end
  end

  defp ingest_apply_peers(hash, peers, filtered_dropped, pex_source) do
    if pex_source?(pex_source) do
      :ok = Peer.ConnectionManager.apply_pex_delta(hash, pex_source, peers, filtered_dropped)
    else
      if peers != [], do: Acceptor.handshakes(peers, hash)
    end
  end

  defp pex_source?(pex_source),
    do: is_binary(pex_source) and byte_size(pex_source) == 20

  @doc false
  @spec prioritize_seed_peers([Peer.t()]) :: [Peer.t()]
  def prioritize_seed_peers(peers) when is_list(peers) do
    Enum.sort_by(peers, fn %Peer{seed: seed} -> seed != true end)
  end

  @doc """
  Pushes the current eligible snapshot to every connected ut_pex peer.

  Each controller diffs against its own `pex_outbound.sent`, applies BEP 11 caps,
  and encodes a separate wire payload (no torrent-global pre-encoded delta).
  """
  @spec broadcast_snapshot(Torrent.hash(), %{endpoint() => Entry.t()}) :: :ok
  def broadcast_snapshot(hash, current) when is_map(current) do
    if allowed?(hash) do
      try do
        hash
        |> Torrent.Swarm.peer_supervisors()
        |> Enum.each(fn pid ->
          if key = Peer.get_key(pid), do: Peer.Controller.send_pex_snapshot(key, current)
        end)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @doc false
  @spec drop_self(map(), endpoint() | nil) :: %{endpoint() => Entry.t()}
  def drop_self(current, nil), do: current

  def drop_self(current, self_ep) when is_map(current), do: Map.delete(current, self_ep)

  @doc false
  @spec outbound_delta(%{endpoint() => Entry.t()}, %{endpoint() => Entry.t()}) ::
          {[Entry.t()], [endpoint()]}
  def outbound_delta(sent, current) when is_map(sent) and is_map(current) do
    added =
      current
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(sent, &1))
      |> Enum.map(&Map.fetch!(current, &1))

    dropped =
      sent
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(current, &1))

    {added, dropped}
  end

  @doc false
  @spec advance_sent_map(%{endpoint() => Entry.t()}, EncodeReport.t()) :: %{
          endpoint() => Entry.t()
        }
  def advance_sent_map(sent, %EncodeReport{} = report) when is_map(sent) do
    sent
    |> Map.drop(report.dropped_endpoints)
    |> Map.merge(Map.new(report.added_entries, &{Entry.endpoint(&1), &1}))
  end

  @doc """
  Sends a ut_pex delta to every connected peer that advertises `ut_pex`.

  Deprecated for outbound churn — prefer `broadcast_snapshot/2` so each connection
  tracks its own sent set. Kept for tests and direct delta injection.
  """
  @spec broadcast(Torrent.hash(), [entry_input()], [entry_input()], keyword()) ::
          {:ok, EncodeReport.t()} | :ok
  def broadcast(hash, added, dropped, opts \\ []) do
    opts = Keyword.put_new(opts, :initial?, false)

    with true <- allowed?(hash),
         {:ok, payload, report} <- encode_delta(added, dropped, opts) do
      broadcast_pex_to_swarm(hash, payload)
      {:ok, report}
    else
      _ -> :ok
    end
  end

  defp broadcast_pex_to_swarm(hash, payload) do
    hash
    |> Torrent.Swarm.peer_supervisors()
    |> Enum.each(fn pid ->
      if key = Peer.get_key(pid), do: Peer.Controller.send_pex(key, payload)
    end)
  end

  @doc """
  Encodes a PEX message with libtorrent-style caps and returns what actually fit.

  Non-initial messages truncate to at most #{@max_non_initial_added} combined added
  and #{@max_non_initial_dropped} combined dropped peers. Initial messages use a
  separate defensive bound (`#{@max_initial_added}` added) and ignore the 50-cap.
  """
  @spec encode_delta([entry_input()], [entry_input()], keyword()) ::
          {:ok, binary(), EncodeReport.t()} | {:error, term()}
  def encode_delta(added, dropped, opts \\ []) do
    initial? = Keyword.get(opts, :initial?, false)

    added_entries = added |> Enum.map(&Entry.normalize/1) |> dedupe_entries()
    dropped_endpoints = dropped |> Enum.map(&Entry.normalize/1) |> dedupe_endpoints()

    added_cap = if initial?, do: @max_initial_added, else: @max_non_initial_added
    dropped_cap = if initial?, do: @max_initial_added, else: @max_non_initial_dropped

    {added_enc, added_trunc} = take_prefix(added_entries, added_cap)
    {dropped_enc, dropped_trunc} = take_prefix_endpoints(dropped_endpoints, dropped_cap)

    report = %EncodeReport{
      initial?: initial?,
      added_total: length(added_entries),
      dropped_total: length(dropped_endpoints),
      added_encoded: length(added_enc),
      dropped_encoded: length(dropped_enc),
      added_truncated: added_trunc,
      dropped_truncated: dropped_trunc,
      added_entries: added_enc,
      dropped_endpoints: dropped_enc
    }

    case build_payload(added_enc, dropped_enc) do
      nil -> {:error, :empty}
      payload -> {:ok, payload, report}
    end
  end

  @doc false
  @spec encode([entry_input()], [entry_input()], keyword()) :: binary() | nil
  def encode(added, dropped, opts \\ []) do
    case encode_delta(added, dropped, opts) do
      {:ok, payload, _} -> payload
      {:error, _} -> nil
    end
  end

  @doc false
  @spec decode(binary(), keyword()) :: {:ok, [Peer.t()], [Peer.t()]} | :error
  def decode(payload, opts \\ []) when is_binary(payload) do
    if byte_size(payload) > @max_inbound_payload_bytes do
      :error
    else
      decode_bento_payload(payload, opts)
    end
  end

  defp decode_bento_payload(payload, opts) do
    case Bento.decode(payload) do
      {:ok, dict} when is_map(dict) ->
        with :ok <- validate_wire_dict(dict, opts),
             {:ok, added, dropped} <- parse_wire_dict(dict) do
          {:ok, added, dropped}
        else
          :error -> :error
        end

      _ ->
        :error
    end
  end

  @doc false
  @spec entry_from_connection(Peer.Controller.State.t(), :inet.ip_address(), :inet.port_number()) ::
          Entry.t()
  def entry_from_connection(state, ip, port) do
    Entry.new({ip, port}, connection_flags(state))
  end

  @spec connection_flags(Peer.Controller.State.t()) :: byte()
  defp connection_flags(%Peer.Controller.State{} = state) do
    0
    |> flag_if(@flag_encrypted, peer_prefers_encryption?(state))
    |> flag_if(@flag_seed, peer_is_seed?(state))
    |> flag_if(@flag_utp, utp_connection?(state))
    |> flag_if(@flag_holepunch, peer_supports_holepunch?(state))
    |> flag_if(@flag_outgoing, state.connection_origin == :outbound)
  end

  # BEP 11 encryption bit reflects the remote peer's capability (LTEP `e`), not our
  # local MSE preference. If we negotiated MSE, they clearly support encryption too.
  @spec peer_prefers_encryption?(Peer.Controller.State.t()) :: boolean()
  defp peer_prefers_encryption?(%Peer.Controller.State{socket: socket, ltep: ltep}) do
    Peer.Transport.mse?(socket) or ltep_encryption?(ltep)
  end

  @spec ltep_encryption?(Session.t() | nil) :: boolean()
  defp ltep_encryption?(nil), do: false

  defp ltep_encryption?(%Session{} = ltep) do
    case Session.peer_handshake(ltep).e do
      1 -> true
      _ -> false
    end
  end

  @spec peer_is_seed?(Peer.Controller.State.t()) :: boolean()
  defp peer_is_seed?(%Peer.Controller.State{bitfield: :all}), do: true

  defp peer_is_seed?(%Peer.Controller.State{bitfield: bitfield, pieces_count: count})
       when is_binary(bitfield) and is_integer(count) and count > 0,
       do: Torrent.Bitfield.count(bitfield, count) == count

  defp peer_is_seed?(_state), do: false

  @spec utp_connection?(Peer.Controller.State.t()) :: boolean()
  defp utp_connection?(%Peer.Controller.State{socket: socket}) do
    socket
    |> Peer.Transport.raw()
    |> UTP.Socket.utp?()
  end

  @spec peer_supports_holepunch?(Peer.Controller.State.t()) :: boolean()
  defp peer_supports_holepunch?(%Peer.Controller.State{ltep: nil}), do: false

  defp peer_supports_holepunch?(%Peer.Controller.State{ltep: ltep}) do
    Session.peer_supports?(ltep, Peer.UtHolepunch.extension_name())
  end

  @spec flag_if(byte(), byte(), boolean()) :: byte()
  defp flag_if(flags, bit, true), do: Bitwise.bor(flags, bit)
  defp flag_if(flags, _bit, false), do: flags

  @spec build_payload([Entry.t()], [endpoint()]) :: binary() | nil
  defp build_payload(added_entries, dropped_endpoints) do
    added4 = Enum.filter(added_entries, fn %Entry{ip: ip} -> tuple_size(ip) == 4 end)
    added6 = Enum.filter(added_entries, fn %Entry{ip: ip} -> tuple_size(ip) == 8 end)
    {dropped4, dropped6} = split_endpoints(dropped_endpoints)

    fields =
      []
      |> maybe_put("added", encode_ipv4_entries(added4))
      |> maybe_put("added.f", encode_flags(added4))
      |> maybe_put("added6", encode_ipv6_entries(added6))
      |> maybe_put("added6.f", encode_flags(added6))
      |> maybe_put("dropped", encode_ipv4(dropped4))
      |> maybe_put("dropped6", encode_ipv6(dropped6))

    case fields do
      [] -> nil
      _ -> Bento.encode!(Map.new(fields))
    end
  end

  @spec validate_wire_dict(map(), keyword()) :: :ok | :error
  defp validate_wire_dict(dict, opts) do
    with :ok <- validate_compact_fields(dict),
         :ok <- validate_flag_fields(dict),
         :ok <- validate_peer_counts(dict, opts),
         :ok <- validate_no_duplicates(dict),
         :ok <- validate_no_add_drop_conflict(dict),
         :ok <- validate_nonempty_contact(dict) do
      :ok
    else
      :error -> :error
    end
  end

  @spec validate_compact_fields(map()) :: :ok | :error
  defp validate_compact_fields(dict) do
    Enum.reduce_while(@compact_keys, :ok, fn key, :ok ->
      validate_compact_field(dict, key)
    end)
  end

  defp validate_compact_field(dict, key) do
    case Map.get(dict, key) do
      nil ->
        {:cont, :ok}

      bin when is_binary(bin) ->
        if valid_compact?(bin, family_for_key(key)), do: {:cont, :ok}, else: {:halt, :error}

      _ ->
        {:halt, :error}
    end
  end

  @spec validate_flag_fields(map()) :: :ok | :error
  defp validate_flag_fields(dict) do
    pairs = [
      {"added", "added.f"},
      {"added6", "added6.f"}
    ]

    Enum.reduce_while(pairs, :ok, fn {compact_key, flag_key}, :ok ->
      compact = Map.get(dict, compact_key, <<>>)
      peer_count = div(byte_size(compact), compact_unit(compact_key))

      case Map.fetch(dict, flag_key) do
        :error ->
          {:cont, :ok}

        {:ok, flags_bin} when is_binary(flags_bin) and byte_size(flags_bin) == peer_count ->
          {:cont, :ok}

        _ ->
          {:halt, :error}
      end
    end)
  end

  @spec validate_peer_counts(map(), keyword()) :: :ok | :error
  defp validate_peer_counts(dict, opts) do
    added = added_peers(dict)
    dropped = dropped_peers(dict)
    initial? = Keyword.get(opts, :initial?, false)
    max_added = if initial?, do: @max_initial_added, else: @max_non_initial_added
    max_dropped = if initial?, do: @max_initial_added, else: @max_non_initial_dropped

    if added <= max_added and dropped <= max_dropped do
      :ok
    else
      :error
    end
  end

  @spec validate_no_duplicates(map()) :: :ok | :error
  defp validate_no_duplicates(dict) do
    endpoints =
      []
      |> Kernel.++(compact_endpoints(Map.get(dict, "added", <<>>), :inet))
      |> Kernel.++(compact_endpoints(Map.get(dict, "added6", <<>>), :inet6))
      |> Kernel.++(compact_endpoints(Map.get(dict, "dropped", <<>>), :inet))
      |> Kernel.++(compact_endpoints(Map.get(dict, "dropped6", <<>>), :inet6))

    if length(endpoints) == length(Enum.uniq(endpoints)) do
      :ok
    else
      :error
    end
  end

  @spec validate_no_add_drop_conflict(map()) :: :ok | :error
  defp validate_no_add_drop_conflict(dict) do
    added =
      MapSet.new(
        compact_endpoints(Map.get(dict, "added", <<>>), :inet) ++
          compact_endpoints(Map.get(dict, "added6", <<>>), :inet6)
      )

    dropped =
      MapSet.new(
        compact_endpoints(Map.get(dict, "dropped", <<>>), :inet) ++
          compact_endpoints(Map.get(dict, "dropped6", <<>>), :inet6)
      )

    if MapSet.intersection(added, dropped) |> MapSet.to_list() == [] do
      :ok
    else
      :error
    end
  end

  # At least one added or dropped compact field must carry a contact when present.
  @spec validate_nonempty_contact(map()) :: :ok | :error
  defp validate_nonempty_contact(dict) do
    added_bytes =
      byte_size(Map.get(dict, "added", <<>>)) + byte_size(Map.get(dict, "added6", <<>>))

    dropped_bytes =
      byte_size(Map.get(dict, "dropped", <<>>)) + byte_size(Map.get(dict, "dropped6", <<>>))

    if added_bytes > 0 or dropped_bytes > 0, do: :ok, else: :error
  end

  @spec parse_wire_dict(map()) :: {:ok, [Peer.t()], [Peer.t()]} | :error
  defp parse_wire_dict(dict) do
    added =
      decode_peers_with_flags(
        Map.get(dict, "added", <<>>),
        Map.get(dict, "added.f"),
        :inet
      ) ++
        decode_peers_with_flags(
          Map.get(dict, "added6", <<>>),
          Map.get(dict, "added6.f"),
          :inet6
        )

    dropped =
      decode_peers_without_flags(Map.get(dict, "dropped", <<>>), :inet) ++
        decode_peers_without_flags(Map.get(dict, "dropped6", <<>>), :inet6)

    {:ok, added, dropped}
  end

  @spec added_peers(map()) :: non_neg_integer()
  defp added_peers(dict) do
    div(byte_size(Map.get(dict, "added", <<>>)), 6) +
      div(byte_size(Map.get(dict, "added6", <<>>)), 18)
  end

  @spec dropped_peers(map()) :: non_neg_integer()
  defp dropped_peers(dict) do
    div(byte_size(Map.get(dict, "dropped", <<>>)), 6) +
      div(byte_size(Map.get(dict, "dropped6", <<>>)), 18)
  end

  @spec compact_endpoints(binary(), :inet | :inet6) :: [endpoint()]
  defp compact_endpoints(<<>>, _family), do: []

  defp compact_endpoints(compact, family) do
    compact
    |> UDP.parse_compact_peers(family)
    |> Enum.map(fn peer -> {peer.ip, peer.port} end)
  end

  @spec valid_compact?(binary(), :inet | :inet6) :: boolean()
  defp valid_compact?(<<>>, _), do: true

  defp valid_compact?(bin, family) do
    unit = if family == :inet, do: 6, else: 18
    byte_size(bin) > 0 and rem(byte_size(bin), unit) == 0
  end

  @spec family_for_key(String.t()) :: :inet | :inet6
  defp family_for_key("added6"), do: :inet6
  defp family_for_key("dropped6"), do: :inet6
  defp family_for_key(_), do: :inet

  @spec compact_unit(String.t()) :: pos_integer()
  defp compact_unit("added6"), do: 18
  defp compact_unit("dropped6"), do: 18
  defp compact_unit(_), do: 6

  @spec split_endpoints([endpoint()]) :: {[endpoint()], [endpoint()]}
  defp split_endpoints(endpoints) do
    Enum.split_with(endpoints, fn {ip, _} -> tuple_size(ip) == 4 end)
  end

  @spec encode_ipv4_entries([Entry.t()]) :: binary()
  defp encode_ipv4_entries(entries) do
    entries
    |> Enum.map(&Entry.endpoint/1)
    |> encode_ipv4()
  end

  @spec encode_ipv6_entries([Entry.t()]) :: binary()
  defp encode_ipv6_entries(entries) do
    entries
    |> Enum.map(&Entry.endpoint/1)
    |> encode_ipv6()
  end

  @spec encode_ipv4([endpoint()]) :: binary()
  defp encode_ipv4(endpoints) do
    Enum.reduce(endpoints, <<>>, fn
      {{a, b, c, d}, port}, acc -> acc <> <<a, b, c, d, port::16>>
      _, acc -> acc
    end)
  end

  @spec encode_ipv6([endpoint()]) :: binary()
  defp encode_ipv6(endpoints) do
    Enum.reduce(endpoints, <<>>, fn
      {{s1, s2, s3, s4, s5, s6, s7, s8}, port}, acc ->
        acc <> <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16>>

      _, acc ->
        acc
    end)
  end

  @spec encode_flags([Entry.t()]) :: binary()
  defp encode_flags(entries) do
    entries
    |> Enum.map(fn %Entry{flags: flags} -> <<flags>> end)
    |> IO.iodata_to_binary()
  end

  @spec decode_peers_with_flags(binary(), binary() | nil, :inet | :inet6) :: [Peer.t()]
  defp decode_peers_with_flags(<<>>, _flags_bin, _family), do: []

  defp decode_peers_with_flags(compact, flags_bin, family) do
    has_flags? = is_binary(flags_bin) and flags_bin != <<>>

    compact
    |> UDP.parse_compact_peers(family)
    |> Enum.with_index()
    |> Enum.map(fn {peer, idx} ->
      flag = if has_flags?, do: flags_byte(flags_bin, idx), else: 0

      seed =
        if has_flags? do
          Bitwise.band(flag, @flag_seed) != 0
        end

      %Peer{ip: peer.ip, port: peer.port, seed: seed}
    end)
  end

  @spec decode_peers_without_flags(binary(), :inet | :inet6) :: [Peer.t()]
  defp decode_peers_without_flags(<<>>, _family), do: []

  defp decode_peers_without_flags(compact, family) do
    compact
    |> UDP.parse_compact_peers(family)
    |> Enum.map(fn peer -> %Peer{ip: peer.ip, port: peer.port} end)
  end

  @spec flags_byte(binary(), non_neg_integer()) :: byte()
  defp flags_byte(flags_bin, idx) when idx >= 0 do
    if byte_size(flags_bin) > idx, do: :binary.at(flags_bin, idx), else: 0
  end

  @spec dedupe_entries([Entry.t()]) :: [Entry.t()]
  defp dedupe_entries(entries) do
    entries
    |> Enum.reverse()
    |> Enum.uniq_by(&Entry.endpoint/1)
    |> Enum.reverse()
  end

  @spec dedupe_endpoints([Entry.t()]) :: [endpoint()]
  defp dedupe_endpoints(entries) do
    entries
    |> Enum.map(&Entry.endpoint/1)
    |> dedupe_endpoints_list()
  end

  @spec dedupe_endpoints_list([endpoint()]) :: [endpoint()]
  defp dedupe_endpoints_list(endpoints) do
    endpoints
    |> Enum.reverse()
    |> Enum.uniq()
    |> Enum.reverse()
  end

  @spec take_prefix([Entry.t()], pos_integer()) :: {[Entry.t()], non_neg_integer()}
  defp take_prefix(list, max) do
    if length(list) <= max do
      {list, 0}
    else
      {Enum.take(list, max), length(list) - max}
    end
  end

  @spec take_prefix_endpoints([endpoint()], pos_integer()) :: {[endpoint()], non_neg_integer()}
  defp take_prefix_endpoints(list, max) do
    if length(list) <= max do
      {list, 0}
    else
      {Enum.take(list, max), length(list) - max}
    end
  end

  @spec maybe_put([{binary(), binary()}], binary(), binary()) :: [{binary(), binary()}]
  defp maybe_put(fields, _key, <<>>), do: fields

  defp maybe_put(fields, key, value) when is_binary(value), do: [{key, value} | fields]
end
