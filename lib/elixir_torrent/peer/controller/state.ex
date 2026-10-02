defmodule Peer.Controller.State do
  @moduledoc """
  Mutable peer-session state and pure transitions for `Peer.Controller`.
  """

  import Peer, only: [make_key: 2]

  alias Peer.{Controller.FastExtension, HashTransfer, HashWire, Sender}
  alias Peer.LTEP.{Extensions, Session}
  alias Peer.UtPex.{DisconnectReason, Entry, InboundRate, Outbound, RecentCache}
  alias Torrent.{Bitfield, Downloads, HashServe, Model, PiecesStatistic, Superseed, Uploader}

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
    peer_v2_support?: false,
    holepunch: %{pex_endpoints: MapSet.new(), rate: nil},
    # The 50-contact BEP 11 cap does not apply to the first inbound snapshot.
    # This is connection state; an added-only delta is not inherently "initial".
    pex_inbound: %{initial?: true, rate: InboundRate.initial()},
    # BEP 11 outbound is per-connection: each remote that negotiates ut_pex gets its
    # own view of what we already told them (`sent`), not a torrent-global ledger.
    pex_outbound: %{initial_sent?: false, initial_pending?: false, sent: %{}},
    # BEP 9 metadata serving is synchronous, so there is no natural outstanding
    # queue bound. Limit accepted requests per connection/window instead.
    ut_metadata_requests: %{window_started_at: nil, count: 0},
    hash_requests: %{},
    requests: MapSet.new(),
    # Blocks we asked for and then withdrew (wire cancel, repin, or a choke that
    # drops the peer's queue). A cancel is not atomic: the block may already be
    # on the wire, and BEP 6 peers must answer every request exactly once, so a
    # withdrawn block legitimately comes back as a piece or a reject one RTT
    # later. Kept so those answers are recognised instead of read as a protocol
    # violation. Bounded — see put_withdrawn/4.
    #
    # A count per block, not a set: the same block is often requested, withdrawn
    # and requested again, so several answers can be owed for it at once, and
    # BEP 6's exactly-one-answer rule makes the count exact. It also makes the
    # bookkeeping independent of which answer arrives first.
    withdrawn: %{},
    # Previous generation of `withdrawn`. Eviction has to drop the oldest
    # entries, and a map has no order to drop by; retiring a full generation
    # keeps at least @max_withdrawn recent withdrawals alive at all times.
    withdrawn_prev: %{},
    # Blocks that matched neither `requests` nor `withdrawn`. Never fatal on its
    # own (our window is finite), but a peer pushing data we never asked for is
    # spending our bandwidth, so it is capped.
    unsolicited_blocks: 0,
    # Inbound block requests accepted for asynchronous disk reads but not yet
    # sent to the peer. BEP 6 requires a choke to explicitly reject every
    # queued request outside the peer-specific allowed-fast set.
    upload_requests: MapSet.new(),
    # Outbound block requests accepted by a piece worker (:ok from
    # Downloads.request/4) whose {:request, _} callback cast hasn't been
    # processed yet. Counted alongside `requests` in full_requests_queue?/1
    # so a peer advertising BEP 10 reqq=N never has more than N requests in
    # flight — including the gap between piece-worker ack and the controller
    # processing the callback cast (fill_request_pipeline can queue several
    # ack'd requests before their casts drain). Not incremented for :noop
    # (waiting=[], endgame skip) or :error (dead worker). Reset on choke and
    # status change.
    pending_requests: 0,
    rank: 0,
    # Monotonic ms at connect — used by ConnectionManager to evict peers that
    # sat in the swarm cap without delivering bytes (choke-cycling under CGNAT).
    connected_at: 0,
    # Monotonic ms of last received block (piece data). Initialized to
    # connected_at so idle_ms grows from connect until the first block; reset
    # on each handle_piece. Lets ConnectionManager snub peers that stay unchoked
    # but deliver nothing (libtorrent-style idle-while-unchoked, ~30s).
    last_block_at: 0,
    downloaded_bytes: 0,
    # How many blocks to keep in flight to this peer — see request_window/2. One
    # field on purpose (the struct is at credo's field limit):
    #   bucket_at / cur / prev: sliding-window download-rate estimator (see
    #     download_rate/2) — two adjacent buckets of @rate_bucket_ms; `bucket_at`
    #     is when the current bucket began (nil until the first block), `cur` /
    #     `prev` the bytes received in the current / previous bucket;
    #   penalty: set when one of this peer's requests timed out, cleared by its
    #     next block. While set the peer may hold only ONE request (see
    #     cancel_timed_out/4);
    #   scan_at: monotonic ms of the last look at the OTHER active pieces that came
    #     back empty (see continue_on_other_piece/1), so a peer with nothing to
    #     request does not re-scan them on every block that arrives.
    pace: %{bucket_at: nil, cur: 0, prev: 0, penalty: false, scan_at: nil},
    # Monotonic ms when `status` was pinned to the current piece index. Used to
    # release peers stuck choked with zero bytes on one piece (endgame monopoly).
    pinned_at: 0,
    # Bytes received while pinned to the current `status` index (reset when the
    # Swarm moves the pin; kept when the peer continues on another piece by itself,
    # see continue_on_other_piece/1). Distinguishes a fresh useless pin from prior progress on another
    # piece still reflected in `downloaded_bytes`.
    pin_downloaded_bytes: 0,
    superseed_piece: nil,
    # Piece indices this peer supplied single-handedly that then failed their
    # hash check. We stop asking this peer for them. See `hash_check_failed/2`.
    hash_failures: MapSet.new(),
    bitfield: nil,
    interested: false,
    choke: true,
    interested_of_me: false,
    choke_me: true,
    # :outbound when we dialed the peer (BEP 11 added.f outgoing bit); default :inbound.
    connection_origin: :inbound
  ]

  @typep bitfield :: Torrent.bitfield() | :all | :none | nil
  @typep subpiece :: {Torrent.index(), Torrent.begin(), Torrent.length()}
  @typep endpoint :: {:inet.ip_address(), :inet.port_number()}
  @type rank :: {non_neg_integer(), Peer.id()} | nil

  @type t :: %__MODULE__{
          hash: Torrent.hash(),
          id: Peer.id(),
          fast_extension: FastExtension.type(),
          status: Peer.status(),
          pieces_count: pos_integer(),
          socket: Peer.Transport.socket(),
          ltep: Session.t() | nil,
          peer_v2_support?: boolean(),
          holepunch: %{
            pex_endpoints: MapSet.t(endpoint()),
            rate: {integer(), non_neg_integer()} | nil
          },
          pex_inbound: %{initial?: boolean(), rate: map()},
          pex_outbound: %{
            initial_sent?: boolean(),
            initial_pending?: boolean(),
            sent: %{endpoint() => Entry.t()}
          },
          ut_metadata_requests: %{window_started_at: integer() | nil, count: non_neg_integer()},
          hash_requests: %{Peer.HashTransfer.ref() => map()},
          requests: MapSet.t(subpiece()),
          withdrawn: %{subpiece() => pos_integer()},
          withdrawn_prev: %{subpiece() => pos_integer()},
          unsolicited_blocks: non_neg_integer(),
          upload_requests: MapSet.t(subpiece()),
          pending_requests: non_neg_integer(),
          rank: non_neg_integer(),
          connected_at: non_neg_integer(),
          last_block_at: non_neg_integer(),
          downloaded_bytes: non_neg_integer(),
          pace: %{
            bucket_at: integer() | nil,
            cur: non_neg_integer(),
            prev: non_neg_integer(),
            penalty: boolean(),
            scan_at: integer() | nil
          },
          pinned_at: non_neg_integer(),
          pin_downloaded_bytes: non_neg_integer(),
          superseed_piece: Torrent.index() | :all | nil,
          hash_failures: MapSet.t(Torrent.index()),
          bitfield: bitfield(),
          interested: boolean(),
          choke: boolean(),
          interested_of_me: boolean(),
          choke_me: boolean(),
          connection_origin: :inbound | :outbound
        }

  # Per-peer request pipelining (BEP 10 reqq). Throughput per peer is bounded by
  # in-flight-bytes / RTT: 16 × 16 KiB = 256 KiB capped a 150 ms peer at
  # ~1.7 MB/s. 64 × 16 KiB = 1 MiB raises that ceiling to ~7 MB/s while staying
  # far below what mainstream clients accept (they advertise reqq 250-500); when
  # a peer advertises a smaller reqq we honor it instead of overflowing its queue.
  @max_unanswered_requests 64
  # ...but 64 is a CEILING, not a quota. Handing every peer the full 64 on
  # unchoke let the first peer to ask take a whole 1 MiB piece regardless of how
  # fast it was: live, slow uTP seeds delivering 1-2 KB/s each sat on 57-61
  # blocks for 90+ s (a 30 s timeout cycle re-handed them the same blocks) while
  # fast peers, with every block of the 12 active pieces already claimed, had
  # nothing to request and sat idle in 20-38 of 40 snapshots. A queue only has to
  # cover the bandwidth-delay product — rate x RTT — to keep a peer's pipe full;
  # anything beyond that is blocks held hostage for nobody's benefit. So the
  # window follows the measured rate: enough blocks for @request_queue_secs of
  # data at the peer's current speed (libtorrent's request_queue_time, 3 s),
  # between @min_request_window and the 64 above. A peer fast enough to need
  # 64 (>= ~350 KB/s) is unchanged; one at 24 KB/s holds 5, not 64.
  @request_queue_secs 3
  # Where an unmeasured peer starts: 64 KiB, i.e. ~430 KB/s at 150 ms RTT, so a
  # fast peer's first window already measures a rate that justifies growing.
  @min_request_window 4
  # Rate estimator bucket length: the estimate averages the last 2-4 s, so a peer
  # that goes quiet decays to zero within 2 buckets and falls back to the minimum.
  @rate_bucket_ms 2_000
  # A peer with a timed-out request may hold exactly one request until it delivers
  # a block (see cancel_timed_out/4).
  @penalised_request_window 1
  # A peer pinned to a piece that is unchoked, holds requests, and has delivered
  # less than this on the pin AND nothing for @trickle_idle_ms is not "working on"
  # the piece, it is sitting on it. 256 KiB = a quarter of a 1 MiB piece.
  @trickle_pin_bytes 262_144
  @trickle_idle_ms 30_000
  # After a look at the other active pieces found nothing for a peer, do not look
  # again for this long. Each look is one bounded call per candidate piece, and a
  # peer with nothing to request is woken by every block it receives.
  @repin_scan_ms 100
  # A withdrawn block stays recognisable for as long as it can plausibly still be
  # in flight: at most one full pipeline per withdrawal, and a peer can be
  # re-pinned before the previous round's answers land, so allow a few rounds.
  @max_withdrawn 4 * @max_unanswered_requests
  # Roughly 8 MiB of unrequested 16 KiB blocks before we give up on the peer.
  @max_unsolicited_blocks 512
  @request_pipeline_depth 64
  @max_pending_hash_requests 8
  # One metadata response can carry 16 KiB. 128 requests/s still permits about
  # 2 MiB/s per peer while bounding CPU, mailbox work, and upload amplification.
  @ut_metadata_request_limit 128
  @ut_metadata_request_window_ms 1_000
  # How long a peer may stay pinned to a piece with choke_me and zero bytes on
  # that pin before Swarm may reassign it. Endgame uses a shorter threshold so
  # scarce unchokes rotate across ALL remaining pieces instead of monopolizing
  # the first active index (BEP-3 endgame needs multi-source redundancy).
  @stale_pin_ms 20_000
  @stale_pin_ms_endgame 15_000
  # Same idea for a peer that is *not* choking us and still delivers nothing.
  # That case is the damaging one: a choked peer holds no requests (handle_choke
  # clears them), while an unchoked one keeps a full pipeline, so every block it
  # sits on is unavailable to anybody else and is merely re-timed-out every
  # @timeout_request. Live, two such peers held one whole piece each — 61 and 64
  # blocks, 0 and 48 KiB delivered — while two pieces with all 64 blocks free had
  # no peer at all, and the torrent stopped dead at 99%. The threshold is longer
  # than the choked one and longer than a block timeout, so a merely slow peer
  # gets a full request cycle to prove itself first; this is the same 60 s idea
  # other clients call snubbing.
  @snubbed_pin_ms 60_000
  # How many *distinct* pieces this peer may supply single-handedly that then
  # fail their SHA-1 before we drop the connection. A peer with one or two bad
  # pieces on disk is otherwise perfectly good — a live run had one serve 99.84%
  # of a 1.3 GB torrent correctly — so the per-index skip below carries the fix
  # and disconnecting is reserved for a peer whose whole copy looks wrong.
  @max_hash_failures 3

  @spec key(t()) :: Peer.key()
  def key(state), do: make_key(state.hash, state.id)

  @doc false
  @spec max_hash_failures() :: pos_integer()
  def max_hash_failures, do: @max_hash_failures

  @doc """
  Records a piece this peer supplied alone that failed its hash check.

  BEP 3 verifies pieces, not blocks, so a peer serving corrupt data is only
  detectable after a whole piece is assembled. Nothing else in the download path
  remembers where those bytes came from, so without this the piece picker hands
  the same index straight back to the same peer and the torrent re-downloads it
  forever. The index is remembered and never requested from this peer again;
  only a peer that ruins `@max_hash_failures` different pieces is disconnected.
  """
  @spec hash_check_failed(t(), Torrent.index()) :: t() | {:error, :corrupt_pieces, t()}
  def hash_check_failed(%__MODULE__{} = state, index) do
    failures = MapSet.put(state.hash_failures, index)
    state = %__MODULE__{state | hash_failures: failures}

    Logger.warning(
      "[peer_download] peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} corrupt_piece index=#{index} bad_pieces=#{MapSet.size(failures)}/#{@max_hash_failures}"
    )

    if MapSet.size(failures) >= @max_hash_failures do
      {:error, :corrupt_pieces, state}
    else
      state
    end
  end

  @doc false
  @spec ut_metadata_request_limit() :: pos_integer()
  def ut_metadata_request_limit, do: @ut_metadata_request_limit

  @doc false
  @spec eviction_info(t()) :: %{
          downloaded_bytes: non_neg_integer(),
          age_ms: non_neg_integer(),
          idle_ms: non_neg_integer(),
          useful?: boolean(),
          seeder?: boolean(),
          choke_me?: boolean(),
          in_flight: non_neg_integer()
        }
  def eviction_info(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    %{
      downloaded_bytes: state.downloaded_bytes,
      age_ms: max(now - state.connected_at, 0),
      idle_ms: max(now - state.last_block_at, 0),
      useful?: useful_for_download?(state),
      seeder?: state.bitfield == :all,
      choke_me?: state.choke_me,
      # Blocks we have asked this peer for and not yet received. Lets the snub rule
      # tell "asked and got nothing" (a stalled peer) from "never asked" (we simply
      # had no work for it) — only the former is the peer's fault.
      in_flight: MapSet.size(state.requests) + state.pending_requests
    }
  end

  # Whether this peer can contribute missing pieces we still need. Cheap cases
  # first (interested / :all / :none); full bitfield scan only as fallback.
  @spec useful_for_download?(t()) :: boolean()
  def useful_for_download?(%__MODULE__{bitfield: :none}), do: false

  def useful_for_download?(%__MODULE__{bitfield: :all, hash: hash}) do
    not torrent_complete?(hash)
  end

  def useful_for_download?(%__MODULE__{interested: true}), do: true

  def useful_for_download?(%__MODULE__{} = state), do: peer_has_missing_piece?(state)

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
    unless has_index?(state, index) do
      peer_key = key(state)
      Sender.have(peer_key, index)

      # This path is driven by Torrent.Controller only after a piece was
      # written and hash-verified. Suggesting that same piece is cheap and
      # useful: we know it is immediately serviceable from disk.
      if match?(%FastExtension{}, state.fast_extension) do
        Sender.suggest_piece(peer_key, index)
      end
    end

    state
  end

  @spec choke(t()) :: t()
  def choke(%__MODULE__{choke: true} = state), do: state

  def choke(%__MODULE__{} = state) do
    # BEP 6 ordering is deliberate: the choke must reach the peer before the
    # rejects so it cannot immediately re-request the same non-allowed blocks.
    :ok = Sender.choke(key(state))

    state
    |> flush_choked_uploads()
    |> Map.put(:choke, true)
  end

  @spec unchoke(t()) :: t()
  def unchoke(%__MODULE__{choke: true} = state) do
    log_upload(state, "unchoke_sent", :debug)
    :ok = Sender.unchoke(key(state))
    %__MODULE__{state | choke: false}
  end

  def unchoke(%__MODULE__{choke: false} = state), do: state

  @spec interested(t(), Torrent.index()) :: t()
  def interested(%__MODULE__{status: index} = state, index) do
    check_interested(state)
  end

  def interested(%__MODULE__{} = state, index) do
    # Repinning changes which piece index we pull from. BEP 3 request slots
    # (reqq) are per connection — ghost in-flight entries for the old index
    # saturate full_requests_queue?/1 and block fresh requests on the new pin.
    state
    |> clear_in_flight_requests()
    |> apply_pin(index)
    |> check_interested()
  end

  @spec first_message(t(), non_neg_integer()) :: t()
  def first_message(%__MODULE__{status: :seed} = state, _) do
    if Superseed.active?(state.hash) do
      assign_superseed_piece(state)
    else
      normal_seed_first_message(state)
    end
  end

  def first_message(%__MODULE__{fast_extension: %FastExtension{}} = state, 0) do
    # BEP 9: have_none makes some seeders choke permanently; empty bitfield is safer.
    :ok = Sender.bitfield(key(state))
    log_upload(state, bitfield_log(state), :debug)
    state
  end

  def first_message(state, _) do
    :ok = Sender.bitfield(key(state))
    log_upload(state, bitfield_log(state), :debug)
    state
  end

  @doc """
  Starts BEP 10 negotiation when the peer advertises LTEP.

  The reply is merged asynchronously so failed negotiation cannot block the base
  protocol. Completed torrents also advertise BEP 9 `metadata_size` so magnet
  leechers can fetch metadata.
  """
  @spec start_ltep(t()) :: t()
  def start_ltep(%__MODULE__{} = state) do
    extensions = Extensions.for_peer(state.hash)
    session = Session.new(extensions)

    opts =
      case Torrent.Metadata.metadata_size(state.hash) do
        size when is_integer(size) and size > 0 ->
          [extra_fields: %{"metadata_size" => size}]

        _ ->
          []
      end

    # BEP 10: send immediately, but do not synchronously wait for id 0. A peer
    # may advertise LTEP in its base handshake and never complete the extension
    # handshake; base-protocol traffic must still start and stay live. Sender
    # preserves wire order, so a later valid id-0 message is merged before any
    # following extension payload from that peer.
    case Peer.LTEP.send_handshake(key(state), session, opts) do
      :ok ->
        Map.put(state, :ltep, session)

      {:error, _} ->
        Map.put(state, :ltep, nil)
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

      ut_pex?(state, extended_id) and Peer.UtPex.allowed?(state.hash) ->
        route_inbound_pex(state, payload)

      ut_holepunch?(state, extended_id) ->
        Peer.UtHolepunch.handle_inbound(state, payload)

      true ->
        state
    end
  end

  @spec ut_metadata?(t(), non_neg_integer()) :: boolean()
  defp ut_metadata?(state, extended_id) do
    Session.local_extension_id(state.ltep, Magnet.UtMetadata.extension_name()) ==
      extended_id
  end

  @spec route_inbound_pex(t(), binary()) :: t()
  defp route_inbound_pex(%__MODULE__{} = state, payload) when is_binary(payload) do
    now_ms = System.monotonic_time(:millisecond)
    rate = Map.get(state.pex_inbound, :rate, InboundRate.initial())

    case InboundRate.gate(rate, now_ms) do
      {:reject, rate} ->
        put_in(state.pex_inbound.rate, rate)

      {:allow, rate, kind} ->
        initial? = kind == :initial

        state =
          case Peer.UtPex.ingest(state.hash, payload,
                 initial?: initial?,
                 pex_source: state.id
               ) do
            {:ok, added, dropped} -> update_holepunch_pex(state, added, dropped)
            :error -> state
          end

        %{
          state
          | pex_inbound: %{
              state.pex_inbound
              | initial?: false,
                rate: rate
            }
        }
    end
  end

  @doc false
  @spec record_pex_recent_disconnect(t(), term()) :: :ok
  def record_pex_recent_disconnect(%__MODULE__{} = state, reason) do
    if DisconnectReason.eligible?(reason) and
         DisconnectReason.handshaken?(state) do
      with {:ok, entry} <- pex_entry(state) do
        RecentCache.record(
          state.hash,
          entry,
          System.monotonic_time(:millisecond)
        )
      end
    end

    :ok
  end

  @spec ut_pex?(t(), non_neg_integer()) :: boolean()
  defp ut_pex?(state, extended_id) do
    Session.local_extension_id(state.ltep, Peer.UtPex.extension_name()) == extended_id
  end

  @spec ut_holepunch?(t(), non_neg_integer()) :: boolean()
  defp ut_holepunch?(state, extended_id) do
    Session.local_extension_id(state.ltep, Peer.UtHolepunch.extension_name()) ==
      extended_id
  end

  @spec update_holepunch_pex(t(), [Peer.t()], [Peer.t()]) :: t()
  defp update_holepunch_pex(state, added, dropped) do
    added_endpoints = MapSet.new(added, &{&1.ip, &1.port})
    dropped_endpoints = MapSet.new(dropped, &{&1.ip, &1.port})

    pex_endpoints =
      state.holepunch.pex_endpoints
      |> MapSet.union(added_endpoints)
      |> MapSet.difference(dropped_endpoints)

    put_in(state.holepunch.pex_endpoints, pex_endpoints)
  end

  # After LTEP merge, send one initial added snapshot (200-cap, not 50) if the remote
  # advertises ut_pex and we have not sent initial on this connection yet.
  @spec maybe_send_initial_pex_snapshot(t(), map(), keyword()) :: t()
  defp maybe_send_initial_pex_snapshot(%__MODULE__{} = state, current, opts)
       when is_map(current) do
    if pex_outbound_peer?(state) do
      deliver_pex_delta(state, current, Keyword.put(opts, :initial?, true))
    else
      state
    end
  end

  @spec deliver_pex_delta(t(), map(), keyword()) :: t()
  defp deliver_pex_delta(state, current, opts) do
    self_ep = own_endpoint(state)
    initial? = Keyword.get(opts, :initial?, false)

    {current, _drained} =
      Outbound.prepare_current(state.hash, current,
        state: state,
        self_ep: self_ep,
        now_ms: Keyword.get(opts, :now_ms),
        supplement_recent?: initial?,
        drain_recent?: false
      )

    {added, dropped} = pex_delta_entries(state, current, initial?)
    encode_and_deliver_pex_delta(state, added, dropped, initial?, opts)
  end

  @spec pex_delta_entries(t(), map(), boolean()) :: {list(), list()}
  defp pex_delta_entries(state, current, initial?) do
    clients = client_for_order(state)

    if initial? do
      {Outbound.order_entries(Map.values(current), clients), []}
    else
      {added_raw, dropped_raw} = Peer.UtPex.outbound_delta(state.pex_outbound.sent, current)

      {
        Outbound.order_entries(added_raw, clients),
        Outbound.order_endpoints(dropped_raw, clients)
      }
    end
  end

  @spec encode_and_deliver_pex_delta(t(), list(), list(), boolean(), keyword()) :: t()
  defp encode_and_deliver_pex_delta(state, added, dropped, initial?, opts) do
    case Peer.UtPex.encode_delta(added, dropped, initial?: initial?) do
      {:ok, payload, report} ->
        handle_pex_payload_delivery(state, payload, report, initial?, opts)

      {:error, :empty} when initial? ->
        mark_pex_initial_sent_empty(state)

      {:error, :empty} ->
        state
    end
  end

  @spec handle_pex_payload_delivery(
          t(),
          binary(),
          Peer.UtPex.EncodeReport.t(),
          boolean(),
          keyword()
        ) ::
          t()
  defp handle_pex_payload_delivery(state, payload, report, initial?, opts) do
    case deliver_pex_payload(state, payload, opts) do
      {:ok, state} ->
        apply_pex_encode_report(state, report, initial?)

      {:error, state} when initial? ->
        put_in(state.pex_outbound.initial_pending?, false)

      {:error, state} ->
        state
    end
  end

  @spec mark_pex_initial_sent_empty(t()) :: t()
  defp mark_pex_initial_sent_empty(state) do
    %{
      state
      | pex_outbound: %{
          state.pex_outbound
          | initial_sent?: true,
            initial_pending?: false
        }
    }
  end

  @spec deliver_pex_payload(t(), binary(), keyword()) :: {:ok, t()} | {:error, t()}
  defp deliver_pex_payload(state, payload, opts) do
    case Keyword.get(opts, :send_fun) do
      fun when is_function(fun, 1) ->
        case fun.(payload) do
          :ok -> {:ok, state}
          _ -> {:error, state}
        end

      nil ->
        transmit_pex(state, payload)
    end
  end

  @spec apply_pex_encode_report(t(), Peer.UtPex.EncodeReport.t(), boolean()) :: t()
  defp apply_pex_encode_report(state, report, initial?) do
    sent = Peer.UtPex.advance_sent_map(state.pex_outbound.sent, report)

    %{
      state
      | pex_outbound: %{
          state.pex_outbound
          | sent: sent,
            initial_sent?: state.pex_outbound.initial_sent? or initial?,
            initial_pending?: false
        }
    }
  end

  @spec client_for_order(t()) :: term()
  defp client_for_order(state), do: Outbound.client_refs(state)

  @spec pex_outbound_peer?(t()) :: boolean()
  defp pex_outbound_peer?(%__MODULE__{ltep: nil}), do: false

  defp pex_outbound_peer?(%__MODULE__{} = state) do
    Peer.UtPex.allowed?(state.hash) and
      Session.peer_supports?(state.ltep, Peer.UtPex.extension_name())
  end

  @doc false
  @spec pex_initial_needed?(t()) :: boolean()
  def pex_initial_needed?(%__MODULE__{} = state) do
    pex_outbound_peer?(state) and not state.pex_outbound.initial_sent? and
      not state.pex_outbound.initial_pending?
  end

  @doc false
  @spec mark_pex_initial_pending(t()) :: t()
  def mark_pex_initial_pending(%__MODULE__{} = state) do
    put_in(state.pex_outbound.initial_pending?, true)
  end

  # BEP 11: never tell a peer about their own contact — drop the endpoint we would
  # advertise for this connection (same source as `pex_entry/1`).
  @spec own_endpoint(t()) :: Peer.UtPex.endpoint() | nil
  defp own_endpoint(%__MODULE__{} = state) do
    case pex_entry(state) do
      {:ok, entry} -> Entry.endpoint(entry)
      :error -> nil
    end
  end

  @doc false
  @spec pex_entry(t()) :: {:ok, Entry.t()} | :error
  def pex_entry(%__MODULE__{socket: nil}), do: :error

  def pex_entry(%__MODULE__{} = state) do
    case Peer.Transport.safe_peername(state.socket) do
      {:ok, {ip, port}} -> {:ok, Peer.UtPex.entry_from_connection(state, ip, port)}
      _ -> :error
    end
  end

  @doc false
  @spec set_connection_origin(t(), :inbound | :outbound) :: t()
  def set_connection_origin(%__MODULE__{} = state, origin) when origin in [:inbound, :outbound] do
    %{state | connection_origin: origin}
  end

  @doc """
  Applies the swarm's current eligible PEX snapshot for this connection.

  BEP 11 expects each peer to learn the set we have not yet advertised to *them*;
  caps and spillover are tracked in `pex_outbound.sent`, not on the torrent.
  """
  @spec apply_pex_snapshot(
          t(),
          %{Peer.UtPex.endpoint() => Entry.t()},
          keyword()
        ) :: t()
  def apply_pex_snapshot(%__MODULE__{} = state, current, opts \\ []) when is_map(current) do
    cond do
      not Peer.UtPex.allowed?(state.hash) ->
        state

      not pex_outbound_peer?(state) ->
        state

      not state.pex_outbound.initial_sent? ->
        maybe_send_initial_pex_snapshot(state, current, opts)

      true ->
        deliver_pex_delta(state, current, Keyword.put(opts, :initial?, false))
    end
  end

  @spec send_pex(t(), binary()) :: t()
  def send_pex(%__MODULE__{} = state, payload) when is_binary(payload) do
    case transmit_pex(state, payload) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  @spec transmit_pex(t(), binary()) :: {:ok, t()} | {:error, t()}
  defp transmit_pex(%__MODULE__{ltep: nil} = state, _payload), do: {:error, state}

  defp transmit_pex(%__MODULE__{} = state, payload) do
    ut_id = Session.peer_extension_id(state.ltep, Peer.UtPex.extension_name())

    if Peer.UtPex.allowed?(state.hash) and is_integer(ut_id) and ut_id > 0 and
         Session.peer_supports?(state.ltep, Peer.UtPex.extension_name()) do
      case Peer.LTEP.send_extended(key(state), ut_id, payload) do
        :ok -> {:ok, state}
        _ -> {:error, state}
      end
    else
      {:error, state}
    end
  end

  @spec respond_ut_metadata(t(), binary()) :: t()
  defp respond_ut_metadata(state, payload) do
    ut_id = Session.peer_extension_id(state.ltep, Magnet.UtMetadata.extension_name())

    case Magnet.UtMetadata.decode_message(payload) do
      {:ok, {:request, [piece: piece]}} ->
        case gate_ut_metadata_request(state, System.monotonic_time(:millisecond)) do
          {:allow, state} ->
            serve_ut_metadata_request(state, ut_id, piece)

          {:reject, state} ->
            state
        end

      _ ->
        state
    end
  end

  @spec serve_ut_metadata_request(t(), pos_integer() | nil, non_neg_integer()) :: t()
  defp serve_ut_metadata_request(state, ut_id, piece) do
    case Magnet.UtMetadata.serve_piece(state.hash, piece) do
      {:ok, data, total} when is_integer(ut_id) and ut_id > 0 ->
        reply = Magnet.UtMetadata.encode_data(piece, total, data)
        _ = Peer.LTEP.send_extended(key(state), ut_id, reply)
        state

      _ ->
        maybe_reject_ut_metadata(state, ut_id, piece)
    end
  end

  @spec gate_ut_metadata_request(t(), integer()) :: {:allow, t()} | {:reject, t()}
  defp gate_ut_metadata_request(state, now_ms) do
    %{window_started_at: started_at, count: count} = state.ut_metadata_requests

    cond do
      is_integer(started_at) and now_ms - started_at < @ut_metadata_request_window_ms and
          count >= @ut_metadata_request_limit ->
        {:reject, state}

      is_integer(started_at) and now_ms - started_at < @ut_metadata_request_window_ms ->
        requests = %{window_started_at: started_at, count: count + 1}
        {:allow, %{state | ut_metadata_requests: requests}}

      true ->
        requests = %{window_started_at: now_ms, count: 1}
        {:allow, %{state | ut_metadata_requests: requests}}
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
    member? = member_request?(state, index, begin, length)
    if member?, do: Sender.cancel(key(state), index, begin, length)

    state
    |> delete_request(index, begin, length)
    |> then(&if member?, do: put_withdrawn(&1, index, begin, length), else: &1)
    |> make_request()
  end

  @doc """
  `cancel/4` for a block whose request timed out in the piece worker.

  The worker re-queues the block, and `cancel/4` then immediately tops the peer's
  pipeline back up — from the front of the same queue, so the peer that just sat on
  a block for 30 s was handed it (and the rest of its old window) straight back.
  Live, the same dead peer re-took 57-61 blocks every cycle while faster peers had
  nothing to ask for. A timeout is the strongest evidence we get that a peer is not
  answering, so it is penalised the way libtorrent does: the peer may hold ONE
  request until it delivers a block (`count_block/2` lifts the penalty). Its other
  blocks stay with the worker for whoever asks next; one probe request is enough
  to find out whether the peer is alive without costing the swarm a piece.
  """
  @spec cancel_timed_out(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  def cancel_timed_out(%__MODULE__{} = state, index, begin, length) do
    # Penalty first: cancel/4 ends in make_request/1, which must already see it.
    cancel(%__MODULE__{state | pace: %{state.pace | penalty: true}}, index, begin, length)
  end

  @spec request(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  def request(state, index, begin, length) do
    unless member_request?(state, index, begin, length) do
      Sender.request(key(state), index, begin, length)
      log_download(state, "request_sent index=#{index} begin=#{begin} len=#{length}", :debug)
    end

    # Piece-worker callback cast has been queued; the sync :ok ack we counted in
    # `pending_requests` is now realized in `state.requests` as we process it.
    # Decrement (clamped at 0) so we don't double-count the pipeline.
    state
    |> decrement_pending()
    |> put_request(index, begin, length)
    |> make_request()
  end

  @spec seed(t()) :: t() | {:error, :two_seeders, t()}
  def seed(%__MODULE__{bitfield: :all, status: status} = state) when status != :seed,
    do: {:error, :two_seeders, state}

  def seed(%__MODULE__{} = state) do
    peer_key = key(state)
    if state.interested, do: Sender.not_interested(peer_key)

    state
    |> Map.put(:status, :seed)
    |> Map.put(:interested, false)
    |> advertise_seed_mode(peer_key)
  end

  @doc false
  @spec superseed_assign(t(), Torrent.index() | nil) :: t()
  def superseed_assign(%__MODULE__{} = state, nil) do
    # This can run during a live superseed rotation. BEP 6 permits have_all
    # only immediately after the handshake, so reveal availability with
    # ordinary HAVE messages instead.
    advertise_all_with_haves(state, "superseed_peer_exhausted")
    %{state | superseed_piece: :all}
  end

  def superseed_assign(%__MODULE__{} = state, index) do
    :ok = Sender.have(key(state), index)
    log_upload(state, "superseed_have_sent index=#{index} reason=rotation", :debug)
    %{state | superseed_piece: index}
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
  def upload(%__MODULE__{status: :seed} = state, n),
    do: Map.update!(state, :rank, &(&1 + n))

  def upload(state, _), do: state

  @doc false
  @spec complete_upload(
          t(),
          Torrent.index(),
          Torrent.begin(),
          Torrent.length(),
          binary()
        ) :: {:sent | :cancelled, t()}
  def complete_upload(%__MODULE__{} = state, index, begin, length, block) do
    request = {index, begin, length}

    if MapSet.member?(state.upload_requests, request) do
      Sender.piece(key(state), index, begin, block)

      log_upload(
        state,
        "piece_sent index=#{index} begin=#{begin} len=#{byte_size(block)}",
        :debug
      )

      state =
        state
        |> update_in([Access.key!(:upload_requests)], &MapSet.delete(&1, request))
        |> upload(length)

      {:sent, state}
    else
      # A choke won the controller mailbox race and already rejected/cancelled
      # this request. Dropping the completed disk read preserves BEP 6's
      # exactly-one-response guarantee.
      {:cancelled, state}
    end
  end

  @spec handle_choke(t()) :: t()
  def handle_choke(%__MODULE__{} = state) do
    log_download(state, "choked_by_peer in_flight=#{MapSet.size(state.requests)}", :debug)

    Enum.each(state.requests, fn {index, begin, length} ->
      Downloads.reject(state.hash, index, state.id, begin, length)
    end)

    # Peer choked us → they will drop any queued requests. Reset both the
    # in-flight set and the pending-ack counter so we can re-fill the
    # pipeline from zero on the next unchoke. A Fast peer owes us a reject for
    # each dropped request (BEP 6), and a block already on the wire still
    # arrives, so the set moves to `withdrawn` rather than vanishing.
    %__MODULE__{state | choke_me: true, requests: MapSet.new(), pending_requests: 0}
    |> withdraw_all(state.requests)
  end

  @spec handle_unchoke(t()) :: t()
  def handle_unchoke(%__MODULE__{} = state) do
    log_download(state, "unchoked", :debug)

    %__MODULE__{state | choke_me: false}
    |> fill_request_pipeline()
  end

  defp fill_request_pipeline(state) do
    do_fill_request_pipeline(state, @request_pipeline_depth)
  end

  # Stop when do_make_request makes no progress (noop/error skip/choked) so a
  # drained pin does not hammer the piece worker @request_pipeline_depth times.
  # Each :ok ack still advances pending_requests until reqq is satisfied.
  defp do_fill_request_pipeline(state, 0), do: state

  defp do_fill_request_pipeline(state, remaining) do
    if full_requests_queue?(state) do
      state
    else
      before = pipeline_progress_snapshot(state)
      after_st = do_make_request(state)

      if pipeline_progress_snapshot(after_st) == before do
        after_st
      else
        do_fill_request_pipeline(after_st, remaining - 1)
      end
    end
  end

  @spec pipeline_progress_snapshot(t()) :: {term(), non_neg_integer(), non_neg_integer()}
  defp pipeline_progress_snapshot(%__MODULE__{} = state) do
    {state.status, state.pending_requests, MapSet.size(state.requests)}
  end

  @spec handle_interested(t()) :: t()
  def handle_interested(%__MODULE__{} = state) do
    state = %{state | interested_of_me: true}
    log_upload(state, "interested_received", :debug)
    maybe_optimistic_unchoke(state)
  end

  @spec handle_not_interested(t()) :: t()
  def handle_not_interested(%__MODULE__{} = state) do
    %__MODULE__{state | interested_of_me: false}
    |> choke()
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

        state =
          state
          |> Map.update!(
            :bitfield,
            fn <<prefix::bits-size(^index), _::1, postfix::bits>> ->
              <<prefix::bits, 1::1, postfix::bits>>
            end
          )
          |> check_interested()

        state
        |> rotate_propagated_superseed_piece(index)
        |> maybe_confirm_superseed_exit()
    end
  end

  @spec handle_bitfield(t(), bitfield()) :: t() | {:error, :protocol_error, t()}
  def handle_bitfield(%__MODULE__{bitfield: x} = state, _)
      when not is_nil(x),
      do: {:error, :protocol_error, state}

  def handle_bitfield(%__MODULE__{status: :seed} = state, bitfield) do
    if Superseed.active?(state.hash) do
      do_handle_bitfield(state, bitfield)
    else
      state
    end
  end

  def handle_bitfield(%__MODULE__{} = state, bitfield) do
    do_handle_bitfield(state, bitfield)
  end

  defp do_handle_bitfield(%__MODULE__{} = state, bitfield) do
    cond do
      Bitfield.valid?(bitfield, state.pieces_count) ->
        PiecesStatistic.update(state.hash, bitfield, state.pieces_count)

        state =
          state
          |> Map.put(:bitfield, bitfield)
          |> sync_status_from_model()
          |> ensure_piece_index()

        Logger.debug(
          "[peer_availability] bitfield peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} pieces=#{Bitfield.count(bitfield, state.pieces_count)}/#{state.pieces_count}"
        )

        :ok = Torrent.Controller.kick(state.hash)

        state
        |> check_interested()
        |> sync_superseed_peer_bitfield()
        |> maybe_confirm_superseed_exit()

      Magnet.Bootstrap.active?(state.hash) and
          byte_size(bitfield) > Bitfield.expected_byte_size(state.pieces_count) ->
        Logger.debug(
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
    case request_reject_reason(state, index, begin, length) do
      :ok ->
        do_serve_request(state, index, begin, length)

      {:reject, reason} ->
        reject_upload_request(state, index, begin, length, reason)
    end
  end

  defp request_reject_reason(state, index, begin, length) do
    cond do
      index < 0 or index >= state.pieces_count ->
        {:reject, :bad_index}

      not upload_request_in_bounds?(state.hash, index, begin, length) ->
        {:reject, :bad_bounds}

      Superseed.active?(state.hash) and state.superseed_piece not in [index, :all] ->
        {:reject, :superseed_hidden}

      not Torrent.have?(state.hash, index) ->
        {:reject, :no_piece_on_disk}

      true ->
        :ok
    end
  end

  defp reject_upload_request(state, index, _begin, _length, :bad_index) do
    log_upload(state, "request_reject index=#{index} reason=bad_index", :debug)
    {:error, :protocol_error, state}
  end

  defp reject_upload_request(state, index, begin, length, :bad_bounds) do
    log_upload(
      state,
      "request_reject index=#{index} begin=#{begin} len=#{length} reason=bad_bounds",
      :debug
    )

    {:error, :protocol_error, state}
  end

  defp reject_upload_request(state, index, begin, length, :superseed_hidden) do
    log_upload(state, "request_reject index=#{index} reason=superseed_hidden", :debug)

    if state.fast_extension != nil do
      Sender.reject(key(state), index, begin, length)
    end

    state
  end

  defp reject_upload_request(state, index, begin, length, :no_piece_on_disk) do
    # Bitfield vs disk can race during verify/invalidate. BEP 6 reject (or
    # silent ignore without Fast) is enough — protocol_error would tear down
    # the whole peer via one_for_all and lose a productive remote seeder.
    model_count =
      case Torrent.get(state.hash, :bitfield) do
        bf when is_binary(bf) -> Torrent.Bitfield.count(bf, state.pieces_count)
        _ -> 0
      end

    log_upload(
      state,
      "request_reject index=#{index} reason=no_piece_on_disk model_pieces=#{model_count}",
      :debug
    )

    if state.fast_extension != nil do
      Sender.reject(key(state), index, begin, length)
    end

    state
  end

  defp upload_request_in_bounds?(hash, index, begin, length) do
    piece_length = Model.piece_length(hash, index)

    is_integer(begin) and begin >= 0 and is_integer(length) and length > 0 and
      length <= Downloads.piece_max_length() and is_integer(piece_length) and
      begin + length <= piece_length
  end

  defp do_serve_request(state, index, begin, length) do
    allowed_while_choked? = FastExtension.upload?(state.fast_extension, index)
    request = {index, begin, length}

    log_upload(
      state,
      "request index=#{index} begin=#{begin} len=#{length} choked=#{state.choke}",
      :debug
    )

    state = maybe_reject_choked_request(state, index, begin, length, allowed_while_choked?)
    serve_upload_request(state, index, begin, length, request, allowed_while_choked?)
  end

  defp maybe_reject_choked_request(state, index, begin, length, allowed_while_choked?) do
    if state.choke and state.fast_extension != nil and not allowed_while_choked? do
      log_upload(
        state,
        "reject index=#{index} begin=#{begin} len=#{length} reason=choked",
        :debug
      )

      Sender.reject(key(state), index, begin, length)
    end

    state
  end

  defp serve_upload_request(state, index, begin, length, request, allowed_while_choked?) do
    cond do
      duplicate_fast_request?(state, request) ->
        Sender.reject(key(state), index, begin, length)
        state

      not state.choke or allowed_while_choked? ->
        enqueue_peer_upload(state, index, begin, length, request)

      true ->
        state
    end
  end

  defp duplicate_fast_request?(state, request) do
    match?(%FastExtension{}, state.fast_extension) and
      MapSet.member?(state.upload_requests, request)
  end

  defp enqueue_peer_upload(state, index, begin, length, request) do
    pid = self()
    sender_key = key(state)
    callback = upload_complete_callback(state, pid, sender_key, index, begin, length)

    case Uploader.request(state.hash, state.id, index, begin, length, callback) do
      {:ok, _task} when not is_nil(state.fast_extension) ->
        update_in(state.upload_requests, &MapSet.put(&1, request))

      {:ok, _task} ->
        state

      {:error, reason} ->
        log_upload(
          state,
          "request_reject index=#{index} begin=#{begin} len=#{length} reason=#{inspect(reason)}",
          :debug
        )

        if match?(%FastExtension{}, state.fast_extension) do
          Sender.reject(key(state), index, begin, length)
        end

        state
    end
  end

  defp upload_complete_callback(state, pid, sender_key, index, begin, length) do
    if match?(%FastExtension{}, state.fast_extension) do
      fn block ->
        GenServer.call(pid, {:complete_upload, index, begin, length, block})
      end
    else
      fn block ->
        Sender.piece(sender_key, index, begin, block)

        log_upload(
          state,
          "piece_sent index=#{index} begin=#{begin} len=#{byte_size(block)}",
          :debug
        )

        GenServer.cast(pid, {:upload, [length]})
      end
    end
  end

  @spec handle_piece(t(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          t() | {:error, :protocol_error, t()}
  def handle_piece(state, index, begin, length) do
    case classify_answer(state, index, begin, length) do
      :requested ->
        count_block(state, length)
        |> delete_request(index, begin, length)
        |> make_request()

      :withdrawn ->
        # The block was already on the wire when we cancelled. The payload is
        # stored either way (the controller hands it to the piece worker before
        # this cast), so count it and keep the peer.
        count_block(state, length)
        |> drop_withdrawn(index, begin, length)
        |> make_request()

      :unsolicited ->
        note_unsolicited(state, "piece index=#{index} begin=#{begin} len=#{length}")
    end
  end

  @spec count_block(t(), Torrent.length()) :: t()
  defp count_block(%__MODULE__{} = state, length) do
    now = System.monotonic_time(:millisecond)

    %__MODULE__{
      state
      | rank: state.rank + length,
        downloaded_bytes: state.downloaded_bytes + length,
        pin_downloaded_bytes: state.pin_downloaded_bytes + length,
        last_block_at: now,
        # A delivered block proves the peer is alive: lift any timeout penalty
        # (the rate-based window then takes over, and decays to the minimum if the
        # peer was only briefly responsive).
        pace: %{track_rate(state.pace, now, length) | penalty: false}
    }
  end

  # Adds `bytes` to the current rate bucket, rolling the buckets forward first.
  @spec track_rate(map(), integer(), non_neg_integer()) :: map()
  defp track_rate(%{bucket_at: nil} = pace, now, bytes),
    do: %{pace | bucket_at: now, cur: bytes, prev: 0}

  defp track_rate(pace, now, bytes) do
    {at, cur, prev} = roll_rate(pace, now)
    %{pace | bucket_at: at, cur: cur + bytes, prev: prev}
  end

  # Moves the (at, cur, prev) bucket triple forward to `now`: one bucket elapsed
  # shifts cur into prev, two or more means the whole window is empty.
  @spec roll_rate(map(), integer()) :: {integer(), non_neg_integer(), non_neg_integer()}
  defp roll_rate(%{bucket_at: at, cur: cur, prev: prev}, now) do
    elapsed = now - at

    cond do
      elapsed < @rate_bucket_ms -> {at, cur, prev}
      elapsed < 2 * @rate_bucket_ms -> {at + @rate_bucket_ms, 0, cur}
      true -> {now, 0, 0}
    end
  end

  @doc """
  Measured download rate from this peer in bytes/second, over the last 2-4 s.

  A sliding window built from two buckets: the whole current bucket plus the
  not-yet-expired share of the previous one, divided by the bucket length. Needs no
  timer — it is rolled lazily when read or written — and a peer that stops sending
  decays to 0 on its own, which a plain "bytes / seconds since connect" would not.
  """
  @spec download_rate(t(), integer()) :: non_neg_integer()
  def download_rate(%__MODULE__{pace: %{bucket_at: nil}}, _now), do: 0

  def download_rate(%__MODULE__{pace: pace}, now) do
    {at, cur, prev} = roll_rate(pace, now)
    # `prev` counts only for the part of its bucket still inside the window.
    prev_share = prev * (@rate_bucket_ms - (now - at)) / @rate_bucket_ms
    trunc((cur + prev_share) * 1000 / @rate_bucket_ms)
  end

  @doc """
  How many blocks we are willing to have in flight to this peer right now.

  Follows the peer's measured rate (see `@request_queue_secs`), is clamped to
  `@min_request_window..@max_unanswered_requests`, never exceeds the peer's own
  BEP 10 `reqq`, and collapses to a single request while a timeout penalty stands.
  """
  @spec request_window(t(), integer()) :: pos_integer()
  def request_window(%__MODULE__{} = state, now \\ System.monotonic_time(:millisecond)) do
    min(adaptive_window(state, now), max_unanswered_requests(state))
  end

  defp adaptive_window(%__MODULE__{pace: %{penalty: true}}, _now), do: @penalised_request_window

  defp adaptive_window(%__MODULE__{} = state, now) do
    block = Downloads.Piece.max_length()
    # ceil(rate * secs / block): the blocks that fit in @request_queue_secs of data.
    wanted = div(download_rate(state, now) * @request_queue_secs + block - 1, block)
    min(max(wanted, @min_request_window), @max_unanswered_requests)
  end

  # DHT (BEP 5 § BitTorrent Protocol Extension)
  @spec handle_port(t(), non_neg_integer()) :: t()
  def handle_port(%__MODULE__{hash: hash} = state, dht_port)
      when is_integer(dht_port) and dht_port in 1..65_535 do
    if Magnet.Bootstrap.active?(hash) do
      state
    else
      case Peer.Transport.safe_peername(state.socket) do
        {:ok, {ip, _port}} ->
          _ = DHT.seed_node(ip, dht_port)
          state

        _ ->
          state
      end
    end
  end

  def handle_port(state, _), do: state

  # FastExtansionMessage begin

  @spec handle_have_all(t()) :: t() | {:error, :two_seeds | :protocol_error, t()}
  def handle_have_all(%__MODULE__{bitfield: bitfield} = state) when not is_nil(bitfield),
    do: {:error, :protocol_error, state}

  def handle_have_all(%__MODULE__{status: :seed} = state) do
    if Superseed.active?(state.hash) do
      state
      |> do_handle_have_all()
      |> maybe_confirm_superseed_exit()
    else
      {:error, :two_seeders, state}
    end
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

    Logger.debug(
      "[peer_availability] have_all peer=#{Peer.log_id(state.id)} hash=#{Torrent.hex_encoded_hash(state.hash)} pieces=#{state.pieces_count} connected=#{Torrent.Swarm.count(state.hash)}"
    )

    :ok = Torrent.Controller.kick(state.hash)

    state
    |> check_interested()
    |> unchoke()
  end

  defp maybe_confirm_superseed_exit(%__MODULE__{status: :seed} = state) do
    complete? =
      state.bitfield == :all or
        (is_binary(state.bitfield) and
           Bitfield.count(state.bitfield, state.pieces_count) == state.pieces_count)

    if complete? and Superseed.confirm_seed(state.hash, state.id) == :deactivated do
      Torrent.Swarm.seed(state.hash)
    end

    state
  end

  defp maybe_confirm_superseed_exit(state), do: state

  @spec handle_have_none(t()) :: t() | {:error, :protocol_error, t()}
  def handle_have_none(%__MODULE__{bitfield: x} = state) when not is_nil(x) do
    {:error, :protocol_error, state}
  end

  def handle_have_none(%__MODULE__{status: :seed} = state) do
    %__MODULE__{state | bitfield: :none}
    |> send_allowed_fast()
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
    case classify_answer(state, index, begin, length) do
      :requested ->
        Downloads.reject(state.hash, index, state.id, begin, length)

        state
        |> delete_request(index, begin, length)
        |> make_request()

      # BEP 6 obliges the peer to reject what it drops, so a cancel or a choke
      # earns exactly this message back. The block was already handed back to
      # its piece worker when we withdrew it; nothing left to do but keep the
      # peer.
      :withdrawn ->
        drop_withdrawn(state, index, begin, length)

      :unsolicited ->
        note_unsolicited(state, "reject index=#{index} begin=#{begin} len=#{length}")
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
    |> make_request()
  end

  @spec handle_hash_request(t(), HashWire.t()) :: t()
  def handle_hash_request(%__MODULE__{} = state, %HashWire{} = req) do
    sender_key = key(state)

    deliver = fn
      {:hashes, hashes} ->
        blob = IO.iodata_to_binary(hashes)

        case HashWire.validate_hashes_payload(req, blob) do
          :ok -> Sender.hashes(sender_key, req, blob)
          _ -> Sender.hash_reject(sender_key, req)
        end

      :reject ->
        Sender.hash_reject(sender_key, req)
    end

    _ = HashServe.serve(state.hash, req, sender_key, deliver)
    state
  end

  @spec handle_hashes(t(), HashWire.t(), binary()) :: t() | {:error, :protocol_error, t()}
  def handle_hashes(%__MODULE__{} = state, %HashWire{} = req, hashes_binary) do
    case take_hash_request(state, req) do
      {nil, _state} ->
        state

      {pending, state} ->
        handle_pending_hashes(state, pending, req, hashes_binary)
    end
  end

  @spec handle_pending_hashes(t(), map(), HashWire.t(), binary()) ::
          t() | {:error, :protocol_error, t()}
  defp handle_pending_hashes(state, pending, req, hashes_binary) do
    with :ok <- HashWire.validate_hashes_payload(req, hashes_binary),
         {:ok, block_count} <- hash_verify_block_count(state.hash, req),
         {:ok, {base, proof}} <- HashWire.split_hashes(req, hashes_binary),
         all = base ++ proof,
         true <-
           verify_merkle_hashes(req, all, block_count) do
      HashTransfer.notify(pending.caller, pending.ref, {:ok, req, all})
      state
    else
      _ ->
        HashTransfer.notify(pending.caller, pending.ref, {:error, :protocol_error, req})
        {:error, :protocol_error, state}
    end
  end

  @spec verify_merkle_hashes(HashWire.t(), list(), non_neg_integer()) :: boolean()
  defp verify_merkle_hashes(req, all, block_count) do
    Torrent.Merkle.verify_hashes(
      req.pieces_root,
      req.base_layer,
      req.index,
      req.length,
      req.proof_layers,
      all,
      block_count
    )
  end

  @spec handle_hash_reject(t(), HashWire.t()) :: t()
  def handle_hash_reject(%__MODULE__{} = state, %HashWire{} = req) do
    case take_hash_request(state, req) do
      {nil, state} ->
        state

      {pending, state} ->
        HashTransfer.notify(pending.caller, pending.ref, {:reject, req})
        state
    end
  end

  @doc false
  @spec notify_hash_request_disconnect(t(), term()) :: :ok
  def notify_hash_request_disconnect(%__MODULE__{hash_requests: requests}, _reason)
      when map_size(requests) == 0,
      do: :ok

  def notify_hash_request_disconnect(%__MODULE__{} = state, _reason) do
    Enum.each(state.hash_requests, fn {_key, pending} ->
      Process.cancel_timer(pending.timer)
      HashTransfer.notify(pending.caller, pending.ref, {:disconnect, pending.request})
    end)

    :ok
  end

  @doc false
  @spec start_hash_request(t(), HashWire.t(), pid(), timeout()) ::
          {:ok, reference(), t()} | {:error, term(), t()}
  def start_hash_request(%__MODULE__{peer_v2_support?: false} = state, _req, _caller, _timeout) do
    {:error, :peer_not_v2, state}
  end

  def start_hash_request(%__MODULE__{} = state, %HashWire{} = req, caller, timeout) do
    req_key = HashTransfer.request_key(req)

    cond do
      Map.has_key?(state.hash_requests, req_key) ->
        {:error, :already_pending, state}

      map_size(state.hash_requests) >= @max_pending_hash_requests ->
        {:error, :too_many_pending, state}

      true ->
        case HashServe.validate_outbound(state.hash, req) do
          :ok -> enqueue_hash_request(state, req, req_key, caller, timeout)
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  @spec enqueue_hash_request(t(), HashWire.t(), term(), pid(), timeout()) ::
          {:ok, reference(), t()}
  defp enqueue_hash_request(state, req, req_key, caller, timeout) do
    ref = make_ref()
    timer = Process.send_after(self(), {:hash_request_timeout, ref}, timeout)
    pending = %{ref: ref, request: req, caller: caller, timer: timer}
    :ok = Sender.hash_request(key(state), req)

    {:ok, ref,
     %{
       state
       | hash_requests: Map.put(state.hash_requests, req_key, pending)
     }}
  end

  @doc false
  @spec drop_hash_request(t(), reference()) :: {map() | nil, t()}
  def drop_hash_request(%__MODULE__{} = state, ref) do
    case find_hash_request(state, ref) do
      nil ->
        {nil, state}

      {key, pending} ->
        Process.cancel_timer(pending.timer)
        {pending, %{state | hash_requests: Map.delete(state.hash_requests, key)}}
    end
  end

  defp take_hash_request(%__MODULE__{} = state, %HashWire{} = req) do
    key = HashTransfer.request_key(req)

    case Map.fetch(state.hash_requests, key) do
      {:ok, pending} ->
        Process.cancel_timer(pending.timer)
        {pending, %{state | hash_requests: Map.delete(state.hash_requests, key)}}

      :error ->
        {nil, state}
    end
  end

  defp find_hash_request(%__MODULE__{hash_requests: requests}, ref) do
    Enum.find_value(requests, fn {key, pending} ->
      if pending.ref == ref, do: {key, pending}
    end)
  end

  defp hash_verify_block_count(hash, %HashWire{pieces_root: root}) do
    case Torrent.FileHandle.context(hash) do
      %{v2_merkle: %{files: files}} ->
        case Enum.find(files, &(&1.pieces_root == root)) do
          %{length: len} when is_integer(len) and len > 0 ->
            {:ok, Torrent.Merkle.file_block_count(len)}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @spec send_allowed_fast(t()) :: t()
  def send_allowed_fast(%__MODULE__{fast_extension: %FastExtension{allowed_fast: set}} = state) do
    # Avoid re-sending if we already computed/sent it for this connection.
    if MapSet.size(set) > 0 do
      state
    else
      # safe_peername: seed startup may race peer teardown — uTP GenServer can be
      # gone while Controller still runs LTEP post-handshake (allowed-fast set).
      case Peer.Transport.safe_peername(state.socket) do
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
    case download_request_skip_reason(state, index) do
      nil -> apply_download_request(state, index)
      reason -> log_download_request_skip(state, index, reason)
    end
  end

  defp do_make_request(%__MODULE__{interested: false, status: index} = state)
       when is_integer(index) do
    log_download(state, "request_skip not_interested index=#{index}", :debug)
    state
  end

  defp do_make_request(state), do: state

  @spec download_request_skip_reason(t(), Torrent.index()) ::
          :queue_full | :choked | :corrupt_source | nil
  defp download_request_skip_reason(state, index) do
    cond do
      MapSet.member?(state.hash_failures, index) -> :corrupt_source
      full_requests_queue?(state) -> :queue_full
      state.choke_me and not FastExtension.download?(state.fast_extension, index) -> :choked
      true -> nil
    end
  end

  @spec log_download_request_skip(t(), Torrent.index(), :queue_full | :choked | :corrupt_source) ::
          t()
  defp log_download_request_skip(state, index, :queue_full) do
    log_download(state, "request_skip queue_full index=#{index}", :debug)
    state
  end

  defp log_download_request_skip(state, index, :choked) do
    log_download(state, "request_skip choked index=#{index}", :debug)
    state
  end

  # This peer already served this piece with a bad hash. Drop the pin as well as
  # the request, otherwise it stays pinned to an index it will never be asked
  # for and stops contributing entirely.
  defp log_download_request_skip(state, index, :corrupt_source) do
    log_download(state, "request_skip corrupt_source index=#{index}", :debug)
    clear_pin(state)
  end

  @spec apply_download_request(t(), Torrent.index()) :: t()
  defp apply_download_request(state, index) do
    pid = self()

    case Downloads.request(
           state.hash,
           index,
           state.id,
           &GenServer.cast(pid, {:request, [&1, &2, &3]})
         ) do
      :error ->
        # Piece worker is gone (verify-fail, timeout, race between our
        # pin and the worker exiting). Clear the pin, then carry on with another
        # active piece if there is one; otherwise the next
        # Swarm.interested_for_piece edge (or a fresh :interested cast from the
        # controller) re-pins us to a live piece.
        log_download(state, "request_skip piece_dead index=#{index}", :debug)

        state
        |> clear_pin()
        |> continue_on_other_piece()

      :noop ->
        # Piece alive but nothing to hand out (waiting=[], endgame cap).
        # Do not touch pending_requests — pre-ack cast used to inflate
        # reqq here and false-saturate fill_request_pipeline.
        log_download(state, "request_skip piece_drained index=#{index}", :debug)
        continue_on_other_piece(state)

      :ok ->
        log_download(state, "request_queued index=#{index}", :debug)
        increment_pending(state)
    end
  end

  # The piece we are pinned to has nothing more for us — keep the pipeline full by
  # moving on to another ACTIVE piece, in this same step.
  #
  # Pieces are small (1 MiB = 64 blocks), so a fast peer reaches the end of one in
  # well under a second. Waiting for an outside signal to name the next piece (a
  # new piece starting, or the 2 s reconcile tick) let its request queue fall to
  # zero at every boundary: live, a 2 MB/s peer had no pin and nothing in flight in
  # 70% of snapshots while 5-6 active pieces held ~400 unclaimed blocks. A
  # request queue only covers the bandwidth-delay product if the next block is
  # already requested when the last one arrives, so the peer has to be able to
  # continue across the boundary on its own.
  #
  # Deliberately NOT `interested/2`: that cancels every in-flight request because
  # the Swarm is moving us for good. Here the requests to the piece we leave are
  # still valid and will arrive; cancelling them would hand their blocks back to
  # the worker and empty the very pipeline we are trying to keep full. The caller
  # has already checked the request window, so one request here keeps us within it.
  #
  # Skipped in endgame, where the Swarm spreads peers over the remaining pieces by
  # a stable hash and redundancy caps decide who may ask for what; hopping
  # between pieces here would fight that. `:none` leaves us exactly where we were
  # before this existed — waiting for the next piece start or reconcile tick.
  @spec continue_on_other_piece(t()) :: t()
  defp continue_on_other_piece(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)

    if repin_scan_due?(state, now) and not endgame?(state.hash) do
      scan_other_pieces(state, now)
    else
      state
    end
  end

  defp scan_other_pieces(%__MODULE__{} = state, now) do
    pid = self()
    from = state.status

    result =
      Downloads.request_any(
        state.hash,
        state.id,
        &repin_candidate?(state, &1, from),
        &GenServer.cast(pid, {:request, [&1, &2, &3]})
      )

    case result do
      {:ok, index} ->
        log_download(state, "request_repin from=#{inspect(from)} to=#{index}", :debug)

        state
        |> move_pin(index)
        |> increment_pending()

      :none ->
        %__MODULE__{state | pace: %{state.pace | scan_at: now}}
    end
  end

  @spec repin_scan_due?(t(), integer()) :: boolean()
  defp repin_scan_due?(%__MODULE__{pace: %{scan_at: nil}}, _now), do: true
  defp repin_scan_due?(%__MODULE__{pace: %{scan_at: at}}, now), do: now - at >= @repin_scan_ms

  # The peer-side half of "may we ask this peer for that piece": it must have the
  # piece, must not be a proven bad source for it, and while it chokes us only the
  # BEP 6 allowed-fast set may be requested. Window and penalty were enforced by
  # the caller (`full_requests_queue?/1`), and `Downloads.request_any/4` only
  # offers pieces that are already active.
  @spec repin_candidate?(t(), Torrent.index(), Torrent.index() | nil) :: boolean()
  defp repin_candidate?(%__MODULE__{} = state, index, from) do
    index != from and has_index?(state, index) and
      not MapSet.member?(state.hash_failures, index) and
      (not state.choke_me or FastExtension.download?(state.fast_extension, index))
  end

  # Same assignment, next piece: keep `pinned_at` / `pin_downloaded_bytes` so the
  # "useless pin" tests still measure how long the peer has gone without delivering,
  # instead of restarting that clock at every boundary. A cleared pin starts fresh.
  @spec move_pin(t(), Torrent.index()) :: t()
  defp move_pin(%__MODULE__{status: nil} = state, index), do: apply_pin(state, index)
  defp move_pin(%__MODULE__{} = state, index), do: %{state | status: index}

  @spec endgame?(Torrent.hash()) :: boolean()
  defp endgame?(hash) do
    Torrent.get(hash, :mode) == :endgame
  catch
    :exit, _ -> false
  end

  @spec check_interested(t()) :: t()
  defp check_interested(%__MODULE__{status: status} = state)
       when is_integer(status) do
    interested = has_index?(state, status)

    if interested != state.interested do
      Sender.interested(key(state), interested)

      if interested do
        log_download(state, "interested_sent index=#{status}", :debug)
      end
    end

    %__MODULE__{state | interested: interested}
    |> make_request()
  end

  defp check_interested(state), do: state

  @spec ensure_piece_index(t()) :: t()
  defp ensure_piece_index(%__MODULE__{status: status} = state) when is_integer(status), do: state

  defp ensure_piece_index(%__MODULE__{hash: hash} = state) do
    case Torrent.get(hash, :peer_status) do
      index when is_integer(index) ->
        log_download(state, "piece_index from_controller index=#{index}", :debug)
        apply_pin(state, index)

      _ ->
        choose_and_pin_piece(state, hash)
    end
  end

  defp choose_and_pin_piece(state, hash) do
    case PiecesStatistic.choice_piece(hash, :random) do
      nil -> pin_from_active_or_none(state, hash)
      index -> pin_chosen_piece(state, index)
    end
  end

  defp pin_from_active_or_none(state, hash) do
    case Downloads.active_indices(hash) do
      [index | _] ->
        log_download(state, "piece_index from_active index=#{index}", :debug)
        apply_pin(state, index)

      [] ->
        log_download(state, "piece_index none_available", :debug)
        state
    end
  end

  defp pin_chosen_piece(state, index) do
    log_download(state, "piece_index chosen=#{index}", :debug)
    apply_pin(state, index)
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

  defp normal_seed_first_message(%__MODULE__{fast_extension: %FastExtension{}} = state) do
    :ok = Sender.have_all(key(state))
    log_upload(state, "have_all_sent reason=connect", :debug)
    state
  end

  defp normal_seed_first_message(%__MODULE__{} = state) do
    :ok = Sender.bitfield(key(state))
    log_upload(state, bitfield_log(state), :debug)
    state
  end

  defp advertise_seed_mode(%__MODULE__{} = state, peer_key) do
    if Superseed.active?(state.hash) do
      assign_superseed_piece(state)
    else
      # have_all is a handshake-time availability replacement, not a
      # mid-session state reset. Regular HAVE messages are valid at any time
      # and also reveal the final piece to peers that saw us complete.
      advertise_all_with_haves(state, "seed_transition", peer_key)

      state
      |> Map.put(:bitfield, nil)
      |> Map.put(:superseed_piece, nil)
      |> seed_allowed_fast()
    end
  end

  defp assign_superseed_piece(%__MODULE__{} = state) do
    case Superseed.assign(state.hash, state.id, state.bitfield) do
      {:ok, index} ->
        :ok = Sender.have(key(state), index)
        log_upload(state, "superseed_have_sent index=#{index} reason=assignment", :debug)
        %{state | superseed_piece: index}

      _ ->
        superseed_assign(state, nil)
    end
  end

  defp rotate_propagated_superseed_piece(%__MODULE__{} = state, index) do
    case Superseed.peer_have(state.hash, state.id, index) do
      {:rotate, assigned_peer, new_piece} when assigned_peer == state.id ->
        superseed_assign(state, new_piece)

      {:rotate, assigned_peer, new_piece} ->
        state.hash
        |> Peer.make_key(assigned_peer)
        |> Peer.Controller.superseed_assign(new_piece)

        state

      :ok ->
        state
    end
  end

  defp sync_superseed_peer_bitfield(%__MODULE__{} = state) do
    if Superseed.active?(state.hash) do
      _ = Superseed.assign(state.hash, state.id, state.bitfield)
      sync_superseed_piece_index(state)
    else
      state
    end
  end

  defp sync_superseed_piece_index(%__MODULE__{superseed_piece: index} = state)
       when is_integer(index) do
    if has_index?(state, index) do
      rotate_propagated_superseed_piece(state, index)
    else
      state
    end
  end

  defp sync_superseed_piece_index(state), do: state

  @spec seed_allowed_fast(t()) :: t()
  defp seed_allowed_fast(%__MODULE__{fast_extension: %FastExtension{}} = state),
    do: send_allowed_fast(state)

  defp seed_allowed_fast(state), do: state

  defp advertise_all_with_haves(%__MODULE__{} = state, reason, peer_key \\ nil) do
    peer_key = peer_key || key(state)
    Enum.each(0..(state.pieces_count - 1), &Sender.have(peer_key, &1))
    log_upload(state, "have_batch_sent pieces=#{state.pieces_count} reason=#{reason}", :debug)
    :ok
  end

  defp flush_choked_uploads(%__MODULE__{fast_extension: nil} = state), do: state

  defp flush_choked_uploads(%__MODULE__{fast_extension: %FastExtension{}} = state) do
    {allowed, rejected} = partition_upload_requests(state)
    cancel_rejected_uploads(state, rejected)
    %{state | upload_requests: MapSet.new(allowed)}
  end

  @spec partition_upload_requests(t()) :: {list(), list()}
  defp partition_upload_requests(state) do
    Enum.split_with(state.upload_requests, fn {index, _begin, _length} ->
      FastExtension.upload?(state.fast_extension, index)
    end)
  end

  @spec cancel_rejected_uploads(t(), list()) :: :ok
  defp cancel_rejected_uploads(state, rejected) do
    Enum.each(rejected, fn {index, begin, length} ->
      :ok = Uploader.cancel(state.hash, state.id, index, begin, length)

      if match?(%FastExtension{}, state.fast_extension) do
        Sender.reject(key(state), index, begin, length)
      end
    end)
  end

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
  defp log_upload(%__MODULE__{hash: hash, id: id}, msg, level) do
    line = "[peer_upload] peer=#{Peer.log_id(id)} hash=#{Torrent.hex_encoded_hash(hash)} #{msg}"

    case level do
      :debug -> Logger.debug(line)
      _ -> Logger.info(line)
    end
  end

  @spec log_download(t(), String.t(), :info | :debug) :: :ok
  defp log_download(%__MODULE__{hash: hash, id: id}, msg, level) do
    line =
      "[peer_download] peer=#{Peer.log_id(id)} hash=#{Torrent.hex_encoded_hash(hash)} #{msg}"

    case level do
      :debug -> Logger.debug(line)
      _ -> Logger.info(line)
    end
  end

  @spec sync_status_from_model(t()) :: t()
  defp sync_status_from_model(%__MODULE__{status: status} = state) when is_integer(status),
    do: state

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

  # Which of our own requests does this piece/reject answer? Treating "not
  # outstanding" as a protocol error banned well-behaved peers for the RTT after
  # every cancel, choke and repin — the ban is torrent-wide, so an aggressive
  # re-pinning scheduler was quietly emptying the swarm.
  @spec classify_answer(t(), Torrent.index(), Torrent.begin(), Torrent.length()) ::
          :requested | :withdrawn | :unsolicited
  defp classify_answer(state, index, begin, length) do
    subpiece = subpiece(index, begin, length)

    cond do
      MapSet.member?(state.requests, subpiece) -> :requested
      Map.has_key?(state.withdrawn, subpiece) -> :withdrawn
      Map.has_key?(state.withdrawn_prev, subpiece) -> :withdrawn
      true -> :unsolicited
    end
  end

  @spec put_withdrawn(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  defp put_withdrawn(%__MODULE__{} = state, index, begin, length) do
    withdrawn = Map.update(state.withdrawn, subpiece(index, begin, length), 1, &(&1 + 1))

    if map_size(withdrawn) > @max_withdrawn do
      %__MODULE__{state | withdrawn: %{}, withdrawn_prev: withdrawn}
    else
      %__MODULE__{state | withdrawn: withdrawn}
    end
  end

  @spec withdraw_all(t(), MapSet.t(subpiece())) :: t()
  defp withdraw_all(state, subpieces) do
    Enum.reduce(subpieces, state, fn {index, begin, length}, acc ->
      put_withdrawn(acc, index, begin, length)
    end)
  end

  @spec drop_withdrawn(t(), Torrent.index(), Torrent.begin(), Torrent.length()) :: t()
  defp drop_withdrawn(%__MODULE__{} = state, index, begin, length) do
    subpiece = subpiece(index, begin, length)

    if Map.has_key?(state.withdrawn, subpiece) do
      %__MODULE__{state | withdrawn: decrement_owed(state.withdrawn, subpiece)}
    else
      %__MODULE__{state | withdrawn_prev: decrement_owed(state.withdrawn_prev, subpiece)}
    end
  end

  @spec decrement_owed(%{subpiece() => pos_integer()}, subpiece()) :: %{
          subpiece() => pos_integer()
        }
  defp decrement_owed(owed, subpiece) do
    case owed do
      %{^subpiece => 1} -> Map.delete(owed, subpiece)
      %{^subpiece => n} -> Map.put(owed, subpiece, n - 1)
      _ -> owed
    end
  end

  @spec note_unsolicited(t(), String.t()) :: t() | {:error, :unsolicited_blocks, t()}
  defp note_unsolicited(%__MODULE__{} = state, what) do
    state = %__MODULE__{state | unsolicited_blocks: state.unsolicited_blocks + 1}
    log_download(state, "unsolicited #{what} total=#{state.unsolicited_blocks}", :debug)

    if state.unsolicited_blocks > @max_unsolicited_blocks do
      # Wasteful, not malicious: drop the connection but leave the peer ID
      # dialable, unlike :protocol_error.
      {:error, :unsolicited_blocks, state}
    else
      state
    end
  end

  @spec full_requests_queue?(t()) :: boolean()
  # Counts in-flight wire requests (`requests`) plus piece-worker :ok acks not
  # yet processed into `requests` (`pending_requests`). Before pending existed,
  # fill_request_pipeline could queue many blocks before callbacks landed —
  # exceeding BEP 10 reqq and getting requests silently dropped by peers.
  defp full_requests_queue?(state),
    do: MapSet.size(state.requests) + state.pending_requests >= request_window(state)

  @spec increment_pending(t()) :: t()
  defp increment_pending(%__MODULE__{} = state),
    do: %__MODULE__{state | pending_requests: state.pending_requests + 1}

  @spec decrement_pending(t()) :: t()
  defp decrement_pending(%__MODULE__{pending_requests: n} = state) when n > 0,
    do: %__MODULE__{state | pending_requests: n - 1}

  defp decrement_pending(state), do: state

  # BEP 10: peers advertise how many requests they are willing to queue (reqq);
  # exceeding it gets requests silently dropped by some clients.
  defp max_unanswered_requests(%__MODULE__{ltep: %Session{peer: %{reqq: reqq}}})
       when is_integer(reqq) and reqq > 0,
       do: min(reqq, @max_unanswered_requests)

  defp max_unanswered_requests(_state), do: @max_unanswered_requests

  @spec torrent_complete?(Torrent.hash()) :: boolean()
  defp torrent_complete?(hash) do
    case Torrent.get(hash, :left) do
      left when is_integer(left) and left <= 0 -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @spec peer_has_missing_piece?(t()) :: boolean()
  defp peer_has_missing_piece?(%__MODULE__{hash: hash, pieces_count: count} = state)
       when is_integer(count) and count > 0 do
    Enum.any?(0..(count - 1), fn index ->
      has_index?(state, index) and not Torrent.have?(hash, index)
    end)
  catch
    :exit, _ -> false
  end

  defp peer_has_missing_piece?(_), do: false

  @doc false
  @spec stale_useless_pin?(t()) :: boolean()
  def stale_useless_pin?(%__MODULE__{status: idx} = state) when is_integer(idx) do
    (state.pin_downloaded_bytes == 0 or trickling_pin?(state)) and
      pin_age_ms(state) >= useless_pin_threshold_ms(state)
  end

  def stale_useless_pin?(_), do: false

  # "Delivered nothing" is too strict a test for sitting on a piece: a peer that
  # trickles one block and then goes quiet has pin_downloaded_bytes > 0 forever
  # and was never released. Live: slow seeds held 57-61 blocks for 78-103 s having
  # delivered 48-224 KiB, the last block 72-96 s earlier. So a pin is also stale
  # when the peer is unchoked and holding requests, has delivered under
  # @trickle_pin_bytes on this pin, and has been silent for @trickle_idle_ms.
  # Releasing it cancels its requests (`interested/2` -> clear_in_flight_requests)
  # and returns the blocks to the piece for peers that are actually delivering.
  @spec trickling_pin?(t()) :: boolean()
  defp trickling_pin?(%__MODULE__{choke_me: true}), do: false

  defp trickling_pin?(%__MODULE__{} = state) do
    MapSet.size(state.requests) > 0 and state.pin_downloaded_bytes < @trickle_pin_bytes and
      System.monotonic_time(:millisecond) - state.last_block_at >= @trickle_idle_ms
  end

  @spec useless_pin_threshold_ms(t()) :: non_neg_integer()
  defp useless_pin_threshold_ms(%__MODULE__{choke_me: true} = state),
    do: stale_pin_threshold_ms(state.hash)

  defp useless_pin_threshold_ms(%__MODULE__{}), do: @snubbed_pin_ms

  # Flush wire cancels + piece-worker rejects before repin or disconnect.
  # Mirrors handle_choke/1 local cleanup but also sends cancels — we are
  # actively switching pieces, not being choked by the remote peer.
  @spec clear_in_flight_requests(t()) :: t()
  defp clear_in_flight_requests(%__MODULE__{} = state) do
    Enum.each(state.requests, fn {index, begin, length} ->
      Sender.cancel(key(state), index, begin, length)
      Downloads.reject(state.hash, index, state.id, begin, length)
    end)

    withdraw_all(%{state | requests: MapSet.new(), pending_requests: 0}, state.requests)
  end

  @spec apply_pin(t(), Torrent.index()) :: t()
  defp apply_pin(%__MODULE__{} = state, index) do
    now = System.monotonic_time(:millisecond)
    %{state | status: index, pinned_at: now, pin_downloaded_bytes: 0}
  end

  @spec clear_pin(t()) :: t()
  defp clear_pin(%__MODULE__{} = state) do
    %{state | status: nil, pending_requests: 0, pinned_at: 0, pin_downloaded_bytes: 0}
  end

  @spec pin_age_ms(t()) :: non_neg_integer()
  defp pin_age_ms(%__MODULE__{pinned_at: 0}), do: 0

  defp pin_age_ms(%__MODULE__{} = state) do
    max(System.monotonic_time(:millisecond) - state.pinned_at, 0)
  end

  @spec stale_pin_threshold_ms(Torrent.hash()) :: non_neg_integer()
  defp stale_pin_threshold_ms(hash) do
    case Torrent.get(hash, :mode) do
      :endgame -> @stale_pin_ms_endgame
      _ -> @stale_pin_ms
    end
  catch
    :exit, _ -> @stale_pin_ms
  end
end
