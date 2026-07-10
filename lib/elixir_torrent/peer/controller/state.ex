defmodule Peer.Controller.State do
  alias Torrent.{Bitfield, PiecesStatistic, Uploader, Downloads}
  alias Peer.{Sender, Controller.FastExtension}

  import Peer, only: [make_key: 2]

  require Logger

  @enforce_keys [:hash, :id, :fast_extension, :status, :pieces_count, :socket]
  defstruct [
    :hash,
    :id,
    :fast_extension,
    :status,
    :pieces_count,
    :socket,
    :peer_reserved,
    :downloaded_at_connect,
    :ltep,
    requests: MapSet.new(),
    rank: 0,
    bitfield: nil,
    interested: false,
    choke: true,
    interested_of_me: false,
    choke_me: true
  ]

  @typep bitfield :: Torrent.bitfield() | :all | :none | nil
  @typep subpiece :: {Torrent.index(), Torrent.begin(), Torrent.length()}
  @type rank :: {non_neg_integer(), Peer.id()} | nil

  @type t :: %__MODULE__{
          hash: Torrent.hash(),
          id: Peer.id(),
          fast_extension: FastExtension.type(),
          status: Peer.status(),
          pieces_count: pos_integer(),
          socket: port(),
          ltep: Peer.LTEP.Session.t() | nil,
          requests: MapSet.t(subpiece()),
          rank: non_neg_integer(),
          bitfield: bitfield(),
          interested: boolean(),
          choke: boolean(),
          interested_of_me: boolean(),
          choke_me: boolean()
        }

  @max_unanswered_requests 20
  @request_pipeline_depth 8

  @spec key(t()) :: Peer.key()
  def key(state), do: make_key(state.hash, state.id)

  @spec rank(t()) :: rank()
  def rank(state) do
    if state.interested_of_me, do: {state.rank, state.id}
  end

  @spec reset_rank(t()) :: t()
  def reset_rank(%__MODULE__{} = state), do: %__MODULE__{state | rank: 0}

  @spec has_index?(t(), Torrent.index()) :: boolean()
  def has_index?(%__MODULE__{bitfield: :all}, _index), do: true

  def has_index?(state, index) do
    case state.bitfield do
      <<_::bits-size(^index), 1::1, _::bits>> ->
        true

      _ ->
        false
    end
  end

  @spec have(t(), Torrent.index()) :: t()
  def have(state, index) do
    unless has_index?(state, index), do: Sender.have(key(state), index)
    state
  end

  @spec choke(t()) :: t()
  def choke(%__MODULE__{} = state) do
    unless state.choke, do: Sender.choke(key(state))
    %__MODULE__{state | choke: true}
  end

  @spec unchoke(t()) :: t()
  def unchoke(%__MODULE__{choke: true} = state) do
    log_upload(state, "unchoke_sent")
    :ok = Sender.unchoke(key(state))
    %__MODULE__{state | choke: false}
  end

  def unchoke(%__MODULE__{choke: false} = state), do: state

  @spec interested(t(), Torrent.index()) :: t()
  def interested(%__MODULE__{} = state, index) do
    %__MODULE__{state | status: index}
    |> check_interested()
  end

  @spec first_message(t(), non_neg_integer()) :: t()
  def first_message(%__MODULE__{status: :seed, fast_extension: %FastExtension{}} = state, _) do
    :ok = Sender.have_all(key(state))
    log_upload(state, "have_all_sent reason=connect")
    state
  end

  def first_message(%__MODULE__{status: :seed} = state, _) do
    :ok = Sender.bitfield(key(state))
    log_upload(state, bitfield_log(state))
    state
  end

  def first_message(%__MODULE__{fast_extension: %FastExtension{}} = state, 0) do
    # BEP 9: have_none makes some seeders choke permanently; empty bitfield is safer.
    :ok = Sender.bitfield(key(state))
    log_upload(state, bitfield_log(state))
    state
  end

  def first_message(state, _) do
    :ok = Sender.bitfield(key(state))
    log_upload(state, bitfield_log(state))
    state
  end

  @doc """
  Performs BEP 10 extension handshake when the peer advertises LTEP.

  Completed torrents also advertise BEP 9 `metadata_size` so magnet leechers can fetch metadata.
  """
  @spec start_ltep(t()) :: t()
  def start_ltep(%__MODULE__{} = state) do
    extensions = Peer.LTEP.Extensions.for_peer(state.hash)
    session = Peer.LTEP.Session.new(extensions)

    opts =
      case Torrent.Metadata.metadata_size(state.hash) do
        size when is_integer(size) and size > 0 ->
          [extra_fields: %{"metadata_size" => size}]

        _ ->
          []
      end

    case Peer.LTEP.handshake_exchange(key(state), session, opts) do
      {:ok, ltep} -> %__MODULE__{state | ltep: ltep}
      {:error, _} -> state
    end
  end

  @spec handle_extended(t(), non_neg_integer(), binary()) :: t()
  def handle_extended(%__MODULE__{ltep: nil} = state, _, _), do: state

  def handle_extended(%__MODULE__{} = state, 0, payload) do
    ltep = Peer.LTEP.merge_handshake(state.ltep, payload)
    %__MODULE__{state | ltep: ltep}
  end

  def handle_extended(%__MODULE__{} = state, extended_id, payload) do
    cond do
      ut_metadata?(state, extended_id) ->
        respond_ut_metadata(state, payload)

      ut_pex?(state, extended_id) ->
        :ok = Peer.UtPex.ingest(state.hash, payload)
        state

      true ->
        state
    end
  end

  @spec ut_metadata?(t(), non_neg_integer()) :: boolean()
  defp ut_metadata?(state, extended_id) do
    Peer.LTEP.Session.local_extension_id(state.ltep, Magnet.UtMetadata.extension_name()) ==
      extended_id
  end


  @spec ut_pex?(t(), non_neg_integer()) :: boolean()
  defp ut_pex?(state, extended_id) do
    Peer.LTEP.Session.local_extension_id(state.ltep, Peer.UtPex.extension_name()) == extended_id
  end

  @spec send_pex(t(), binary()) :: t()
  def send_pex(%__MODULE__{ltep: nil} = state, _), do: state

  def send_pex(%__MODULE__{} = state, payload) when is_binary(payload) do
    ut_id = Peer.LTEP.Session.peer_extension_id(state.ltep, Peer.UtPex.extension_name())

    if is_integer(ut_id) and ut_id > 0 and
         Peer.LTEP.Session.peer_supports?(state.ltep, Peer.UtPex.extension_name()) do
      _ = Peer.LTEP.send_extended(key(state), ut_id, payload)
    end

    state
  end

  @spec respond_ut_metadata(t(), binary()) :: t()
  defp respond_ut_metadata(state, payload) do
    ut_id = Peer.LTEP.Session.peer_extension_id(state.ltep, Magnet.UtMetadata.extension_name())

    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        case Magnet.UtMetadata.serve_piece(state.hash, piece) do
          {:ok, data, total} when is_integer(ut_id) and ut_id > 0 ->
            reply = Magnet.UtMetadata.encode_data(piece, total, data)
            _ = Peer.LTEP.send_extended(key(state), ut_id, reply)
            state

          _ ->
            maybe_reject_ut_metadata(state, ut_id, piece)
        end

      _ ->
        state
    end
  end

  @spec maybe_reject_ut_metadata(t(), pos_integer() | nil, non_neg_integer()) :: t()
  defp maybe_reject_ut_metadata(state, ut_id, piece) when is_integer(ut_id) and ut_id > 0 do
    _ = Peer.LTEP.send_extended(key(state), ut_id, Magnet.UtMetadata.encode_reject(piece))
    state
  end

  defp maybe_reject_ut_metadata(state, _, _), do: state

  @spec cancel(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  def cancel(state, index, begin, length) do
    if member_request?(state, index, begin, length) do
      Sender.cancel(key(state), index, begin, length)
    end

    state
    |> delete_request(index, begin, length)
    |> make_request
  end

  @spec request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  def request(state, index, begin, length) do
    unless member_request?(state, index, begin, length) do
      Sender.request(key(state), index, begin, length)
      log_download(state, "request_sent index=#{index} begin=#{begin} len=#{length}", :debug)
    end

    state
    |> put_request(index, begin, length)
    |> make_request
  end

  @spec seed(t()) :: t() | {:error, :two_seeders, t()}
  def seed(%__MODULE__{bitfield: :all} = x), do: {:error, :two_seeders, x}

  def seed(%__MODULE__{} = state) do
    peer_key = key(state)
    if state.interested, do: Sender.not_interested(peer_key)

    :ok = Sender.have_all(peer_key)
    log_upload(state, "have_all_sent reason=seed_transition")

    state
    |> Map.put(:bitfield, nil)
    |> Map.put(:status, :seed)
    |> Map.put(:interested, false)
    |> seed_allowed_fast()
  end

  @doc """
  Builds peer-wire messages for a protocol-correct shutdown.

  Per BEP 3:
  - cancel in-flight block requests (especially during endgame)
  - send `not interested` when we no longer want data
  - choke so we stop uploading to interested peers

  See also common client behaviour: flush cancels before closing the socket.
  """
  @spec disconnect_operations(t()) :: {[atom() | tuple()], t()}
  def disconnect_operations(%__MODULE__{} = state) do
    cancels =
      Enum.map(state.requests, fn {index, begin, length} ->
        {:cancel, index, begin, length}
      end)

    interest = if state.interested, do: [:not_interested], else: []
    chokes = if state.choke, do: [], else: [:choke]

    state =
      Enum.reduce(state.requests, state, fn {index, begin, length}, acc ->
        Downloads.reject(acc.hash, index, acc.id, begin, length)
        delete_request(acc, index, begin, length)
      end)

    {cancels ++ interest ++ chokes, state}
  end

  @spec upload(t(), Torrent.length()) :: t()
  def upload(%__MODULE__{status: :seed} = state, n) do
    Map.update!(state, :rank, &(&1 + n))
  end

  def upload(state, _), do: state

  @spec handle_choke(t()) :: t()
  def handle_choke(%__MODULE__{} = state) do
    log_download(state, "choked_by_peer in_flight=#{MapSet.size(state.requests)}")

    Enum.each(state.requests, fn {index, begin, length} ->
      Downloads.reject(state.hash, index, state.id, begin, length)
    end)

    %__MODULE__{state | choke_me: true, requests: MapSet.new()}
  end

  @spec handle_unchoke(t()) :: t()
  def handle_unchoke(%__MODULE__{} = state) do
    log_download(state, "unchoked")

    %__MODULE__{state | choke_me: false}
    |> fill_request_pipeline()
  end

  defp fill_request_pipeline(state) do
    Enum.reduce(1..@request_pipeline_depth, state, fn _, st ->
      if full_requests_queue?(st), do: throw(st)
      do_make_request(st)
    end)
  catch
    :throw, st -> st
  end

  @spec handle_interested(t()) :: t()
  def handle_interested(%__MODULE__{} = state) do
    state = %{state | interested_of_me: true}
    log_upload(state, "interested_received")
    maybe_optimistic_unchoke(state)
  end

  @spec handle_not_interested(t()) :: t()
  def handle_not_interested(%__MODULE__{} = state) do
    %__MODULE__{state | interested_of_me: false}
    |> choke
  end

  @spec handle_have(t(), Torrent.index()) :: t() | {:error, :protocol_error, t()}
  def handle_have(%__MODULE__{bitfield: :all} = state, _) do
    {:error, :protocol_error, state}
  end

  def handle_have(%__MODULE__{bitfield: x} = state, index) when x in [nil, :none] do
    %__MODULE__{state | bitfield: Bitfield.make(state.pieces_count)}
    |> handle_have(index)
  end

  def handle_have(state, index) do
    cond do
      Magnet.Bootstrap.active?(state.hash) and index >= state.pieces_count ->
        do_handle_have_all(state)

      has_index?(state, index) ->
        state

      true ->
        PiecesStatistic.inc(state.hash, index)

        state
        |> Map.update!(
          :bitfield,
          fn <<prefix::bits-size(^index), _::1, postfix::bits>> ->
            <<prefix::bits, 1::1, postfix::bits>>
          end
        )
        |> check_interested()
    end
  end

  @spec handle_bitfield(t(), bitfield()) :: t() | {:error, :protocol_error, t()}
  def handle_bitfield(%__MODULE__{bitfield: x} = state, _)
      when not is_nil(x),
      do: {:error, :protocol_error, state}

  def handle_bitfield(%__MODULE__{status: :seed} = x, _), do: x

  def handle_bitfield(%__MODULE__{} = state, bitfield) do
    cond do
      Bitfield.valid?(bitfield, state.pieces_count) ->
        PiecesStatistic.update(state.hash, bitfield, state.pieces_count)

        state =
          state
          |> Map.put(:bitfield, bitfield)
          |> sync_status_from_model()
          |> ensure_piece_index()

        Logger.info(
          "[peer_availability] bitfield peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} pieces=#{Bitfield.count(bitfield, state.pieces_count)}/#{state.pieces_count}"
        )

        :ok = Torrent.Controller.kick(state.hash)

        state
        |> check_interested()

      Magnet.Bootstrap.active?(state.hash) and
          byte_size(bitfield) > Bitfield.expected_byte_size(state.pieces_count) ->
        Logger.info(
          "[peer_availability] bootstrap_bitfield peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} bytes=#{byte_size(bitfield)}"
        )

        do_handle_have_all(state)

      true ->
        {:error, :protocol_error, state}
    end
  end

  @spec handle_request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          t() | {:error, :protocol_error, t()}
  def handle_request(%__MODULE__{hash: hash} = state, index, begin, length) do
    if Magnet.Bootstrap.active?(hash) do
      state
    else
      do_handle_request(state, index, begin, length)
    end
  end

  defp do_handle_request(state, index, begin, length) do
    cond do
      index >= state.pieces_count ->
        log_upload(state, "request_reject index=#{index} reason=bad_index")
        {:error, :protocol_error, state}

      not Torrent.have?(state.hash, index) ->
        model_count =
          case Torrent.get(state.hash, :bitfield) do
            bf when is_binary(bf) -> Torrent.Bitfield.count(bf, state.pieces_count)
            _ -> 0
          end

        log_upload(
          state,
          "request_reject index=#{index} reason=no_piece_on_disk model_pieces=#{model_count}"
        )

        {:error, :protocol_error, state}

      true ->
        do_serve_request(state, index, begin, length)
    end
  end

  defp do_serve_request(state, index, begin, length) do
      allowed_while_choked? = FastExtension.upload?(state.fast_extension, index)

      log_upload(
        state,
        "request index=#{index} begin=#{begin} len=#{length} choked=#{state.choke}"
      )

      if state.choke and state.fast_extension != nil and not allowed_while_choked? do
        log_upload(state, "reject index=#{index} begin=#{begin} len=#{length} reason=choked")
        Sender.reject(key(state), index, begin, length)
      end

      if not state.choke or allowed_while_choked? do
        pid = self()
        sender_key = key(state)

        callback = fn block ->
          Sender.piece(sender_key, index, begin, block)

          log_upload(
            state,
            "piece_sent index=#{index} begin=#{begin} len=#{byte_size(block)}"
          )

          GenServer.cast(pid, {:upload, [length]})
        end

        Uploader.request(state.hash, state.id, index, begin, length, callback)
      end

    state
  end

  @spec handle_piece(t(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          t() | {:error, :protocol_error, t()}
  def handle_piece(state, index, begin, length) do
    if member_request?(state, index, begin, length) do
      state
      |> Map.update!(:rank, &(&1 + length))
      |> delete_request(index, begin, length)
      |> make_request
    else
      {:error, :protocol_error, state}
    end
  end

  # DHT (BEP 5 § BitTorrent Protocol Extension)
  @spec handle_port(t(), non_neg_integer()) :: t()
  def handle_port(%__MODULE__{hash: hash} = state, dht_port)
      when is_integer(dht_port) and dht_port in 1..65535 do
    if Magnet.Bootstrap.active?(hash) do
      state
    else
      case Peer.Transport.peername(state.socket) do
        {:ok, {ip, _port}} ->
          :ok = DHT.seed_node(ip, dht_port)
          state

        _ ->
          state
      end
    end
  end

  def handle_port(state, _), do: state

  # FastExtansionMessage begin

  @spec handle_have_all(t()) :: t() | {:error, :two_seeds | :protocol_error, t()}
  def handle_have_all(%__MODULE__{bitfield: :all} = state), do: state

  def handle_have_all(%__MODULE__{status: :seed} = x), do: {:error, :two_seeders, x}

  def handle_have_all(%__MODULE__{bitfield: bin} = state) when is_binary(bin) do
    state
    |> drop_partial_bitfield(bin)
    |> do_handle_have_all()
  end

  def handle_have_all(%__MODULE__{} = state), do: do_handle_have_all(state)

  defp do_handle_have_all(%__MODULE__{hash: hash} = state) do
    if Magnet.Bootstrap.active?(hash) do
      %{state | bitfield: :all}
    else
      do_handle_have_all_download(state)
    end
  end

  defp do_handle_have_all_download(%__MODULE__{} = state) do
    PiecesStatistic.inc_all(state.hash, state.pieces_count - 1)

    state =
      state
      |> Map.put(:bitfield, :all)
      |> sync_status_from_model()
      |> ensure_piece_index()

    Logger.info(
      "[peer_availability] have_all peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} pieces=#{state.pieces_count} connected=#{Torrent.Swarm.count(state.hash)}"
    )

    :ok = Torrent.Controller.kick(state.hash)

    state
    |> check_interested()
    |> unchoke()
  end

  defp drop_partial_bitfield(%__MODULE__{} = state, bin) when is_binary(bin) do
    PiecesStatistic.remove_peer(state.hash, bin, state.pieces_count)
    %{state | bitfield: nil}
  end

  @spec handle_have_none(t()) :: t() | {:error, :protocol_error, t()}
  def handle_have_none(%__MODULE__{bitfield: x} = state) when not is_nil(x) do
    {:error, :protocol_error, state}
  end

  def handle_have_none(%__MODULE__{status: :seed} = state) do
    %__MODULE__{state | bitfield: :none}
    |> send_allowed_fast
  end

  def handle_have_none(%__MODULE__{} = state), do: %__MODULE__{state | bitfield: :none}

  @spec handle_reject(t(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          t() | {:error, :protocol_error, t()}
  def handle_reject(%__MODULE__{hash: hash} = state, index, begin, length) do
    if Magnet.Bootstrap.active?(hash) do
      state
    else
      do_handle_reject(state, index, begin, length)
    end
  end

  defp do_handle_reject(state, index, begin, length) do
    if member_request?(state, index, begin, length) do
      Downloads.reject(state.hash, index, state.id, begin, length)

      state
      |> delete_request(index, begin, length)
      |> make_request
    else
      {:error, :protocol_error, state}
    end
  end

  # BEP 6: a peer may suggest which piece to download next; honor when we lack it and they have it.
  @spec handle_suggest_piece(t(), Torrent.index()) :: t() | {:error, :protocol_error, t()}
  def handle_suggest_piece(%__MODULE__{hash: hash} = state, index) do
    if Magnet.Bootstrap.active?(hash) do
      state
    else
      do_handle_suggest_piece(state, index)
    end
  end

  defp do_handle_suggest_piece(%__MODULE__{} = state, index) do
    cond do
      index < 0 or index >= state.pieces_count ->
        {:error, :protocol_error, state}

      has_index?(state, index) and not Torrent.have?(state.hash, index) ->
        state
        |> Map.put(:status, index)
        |> check_interested()

      true ->
        state
    end
  end

  @spec handle_allowed_fast(t(), Torrent.index()) :: t()
  def handle_allowed_fast(%__MODULE__{hash: hash} = state, index) do
    if Magnet.Bootstrap.active?(hash) or index < 0 or index >= state.pieces_count do
      state
    else
      do_handle_allowed_fast(state, index)
    end
  end

  defp do_handle_allowed_fast(state, index) do
    unless PiecesStatistic.get_status(state.hash, index) in [:complete, :processing] do
      PiecesStatistic.set(state.hash, index, :allowed_fast)
    end

    state
    |> update_in(
      [Access.key!(:fast_extension), Access.key!(:allowed_fast_me)],
      &MapSet.put(&1, index)
    )
    |> make_request
  end

  @spec send_allowed_fast(t()) :: t()
  def send_allowed_fast(%__MODULE__{fast_extension: %FastExtension{allowed_fast: set}} = state) do
    # Avoid re-sending if we already computed/sent it for this connection.
    if MapSet.size(set) > 0 do
      state
    else
      case Peer.Transport.peername(state.socket) do
        {:ok, {peer_addr, _port}} ->
          set = AllowedFast.set(peer_addr, state.hash, state.pieces_count)

          Enum.each(set, &Sender.allowed_fast(key(state), &1))

          put_in(
            state,
            [Access.key!(:fast_extension), Access.key!(:allowed_fast)],
            set
          )

        _ ->
          state
      end
    end
  end

  # FastExtansionMessage end

  @spec make_request(t()) :: t()
  defp make_request(%__MODULE__{hash: hash} = state) do
    if Magnet.Bootstrap.active?(hash) do
      state
    else
      do_make_request(state)
    end
  end

  @spec do_make_request(t()) :: t()
  defp do_make_request(%__MODULE__{interested: true, status: index} = state)
       when is_integer(index) do
    cond do
      full_requests_queue?(state) ->
        log_download(state, "request_skip queue_full index=#{index}", :debug)

      state.choke_me and not FastExtension.download?(state.fast_extension, index) ->
        log_download(state, "request_skip choked index=#{index}", :debug)

      true ->
        pid = self()

        Downloads.request(
          state.hash,
          index,
          state.id,
          &GenServer.cast(pid, {:request, [&1, &2, &3]})
        )

        log_download(state, "request_queued index=#{index}", :debug)
    end

    state
  end

  defp do_make_request(%__MODULE__{interested: false, status: index} = state)
       when is_integer(index) do
    log_download(state, "request_skip not_interested index=#{index}", :debug)
    state
  end

  defp do_make_request(state), do: state

  @spec check_interested(t()) :: t()
  defp check_interested(%__MODULE__{status: status} = state)
       when is_integer(status) do
    interested = has_index?(state, status)

    if interested != state.interested do
      Sender.interested(key(state), interested)

      if interested do
        log_download(state, "interested_sent index=#{status}")
      end
    end

    %__MODULE__{state | interested: interested}
    |> make_request
  end

  defp check_interested(state), do: state

  @spec ensure_piece_index(t()) :: t()
  defp ensure_piece_index(%__MODULE__{status: status} = state) when is_integer(status), do: state

  defp ensure_piece_index(%__MODULE__{hash: hash} = state) do
    case Torrent.get(hash, :peer_status) do
      index when is_integer(index) ->
        log_download(state, "piece_index from_controller index=#{index}", :debug)
        %{state | status: index}

      _ ->
        case PiecesStatistic.choice_piece(hash, :random) do
          nil ->
            case Downloads.active_indices(hash) do
              [index | _] ->
                log_download(state, "piece_index from_active index=#{index}", :debug)
                %{state | status: index}

              [] ->
                log_download(state, "piece_index none_available", :debug)
                state
            end

          index ->
            log_download(state, "piece_index chosen=#{index}", :debug)
            %{state | status: index}
        end
    end
  end

  @spec maybe_optimistic_unchoke(t()) :: t()
  defp maybe_optimistic_unchoke(%__MODULE__{choke: false} = state), do: state

  defp maybe_optimistic_unchoke(%__MODULE__{} = state) do
    if offers_pieces?(state) do
      unchoke(state)
    else
      log_upload(state, "interested_skip_unchoke reason=no_pieces_to_offer", :debug)
      state
    end
  end

  @spec offers_pieces?(t()) :: boolean()
  defp offers_pieces?(%__MODULE__{status: :seed, hash: hash}) do
    Torrent.Model.downloaded?(hash)
  catch
    :exit, _ -> true
  end

  defp offers_pieces?(%__MODULE__{hash: hash, pieces_count: count}) when count > 0 do
    Enum.any?(0..(count - 1), &Torrent.have?(hash, &1))
  catch
    :exit, _ -> false
  end

  defp offers_pieces?(_), do: false

  @spec seed_allowed_fast(t()) :: t()
  defp seed_allowed_fast(%__MODULE__{fast_extension: %FastExtension{}} = state),
    do: send_allowed_fast(state)

  defp seed_allowed_fast(state), do: state

  @spec bitfield_log(t()) :: String.t()
  defp bitfield_log(%__MODULE__{hash: hash, pieces_count: count}) do
    model =
      case Torrent.get(hash, :bitfield) do
        bf when is_binary(bf) -> Torrent.Bitfield.count(bf, count)
        _ -> 0
      end

    verified =
      Enum.count(0..(count - 1), fn index ->
        Torrent.have?(hash, index)
      end)

    mismatch = if model != verified, do: " mismatch=model=#{model}_verified=#{verified}", else: ""

    case Torrent.get(hash, :bitfield) do
      bf when is_binary(bf) ->
        "bitfield_sent pieces=#{model}/#{count} verified=#{verified} bytes=#{byte_size(bf)}#{mismatch}"

      _ ->
        "bitfield_sent pieces=0/#{count} verified=#{verified}"
    end
  end

  @spec log_upload(t(), String.t(), :info | :debug) :: :ok
  defp log_upload(%__MODULE__{hash: hash, id: id}, msg, level \\ :info) do
    line = "[peer_upload] peer=#{Peer.log_id(id)} hash=#{Torrent.hex_encoded_hash(hash)} #{msg}"

    case level do
      :debug -> Logger.debug(line)
      _ -> Logger.info(line)
    end
  end

  @spec log_download(t(), String.t(), :info | :debug) :: :ok
  defp log_download(%__MODULE__{hash: hash, id: id}, msg, level \\ :info) do
    line =
      "[peer_download] peer=#{Peer.log_id(id)} hash=#{Torrent.hex_encoded_hash(hash)} #{msg}"

    case level do
      :debug -> Logger.debug(line)
      _ -> Logger.info(line)
    end
  end

  @spec sync_status_from_model(t()) :: t()
  defp sync_status_from_model(%__MODULE__{status: status} = state) when is_integer(status), do: state

  defp sync_status_from_model(%__MODULE__{} = state) do
    case Torrent.get(state.hash, :peer_status) do
      index when is_integer(index) -> %{state | status: index}
      _ -> state
    end
  end

  @spec subpiece(Torrent.index(), Torrent.begin(), Torrent.length()) :: subpiece()
  defp subpiece(index, begin, length), do: {index, begin, length}

  @spec put_request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  defp put_request(state, index, begin, length) do
    Map.update!(state, :requests, &MapSet.put(&1, subpiece(index, begin, length)))
  end

  @spec delete_request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  defp delete_request(state, index, begin, length) do
    Map.update!(state, :requests, &MapSet.delete(&1, subpiece(index, begin, length)))
  end

  @spec member_request?(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: boolean()
  defp member_request?(state, index, begin, length) do
    MapSet.member?(state.requests, subpiece(index, begin, length))
  end

  @spec full_requests_queue?(t()) :: boolean()
  defp full_requests_queue?(state), do: MapSet.size(state.requests) >= @max_unanswered_requests
end
