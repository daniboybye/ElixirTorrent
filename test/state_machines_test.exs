defmodule Peer.DialBackoffStateM do
  @moduledoc false
  use PropCheck
  use PropCheck.StateM.ModelDSL

  alias Peer.DialBackoff

  @non_reachability [:already_connected, :not_connectable, :socket_handoff_failed]
  @sticky_reasons [:churn, :econnrefused, :ehostunreach, :enetunreach, :eafnosupport]
  @transient [:timeout, :closed, :handshake_timeout]
  @hard_fail_threshold 3

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}
  @type model :: %{
          hash: Torrent.hash(),
          endpoints: [endpoint()],
          blocks: %{endpoint() => %{fail_count: non_neg_integer(), sticky: boolean()}},
          productive: MapSet.t(endpoint())
        }

  @spec initial_state() :: model()
  def initial_state do
    %{
      hash: <<0::160>>,
      endpoints: [],
      blocks: %{},
      productive: MapSet.new()
    }
  end

  @spec init(Torrent.hash()) :: model()
  def init(hash) when is_binary(hash) and byte_size(hash) == 20 do
    %{
      hash: hash,
      endpoints: [
        {{11, 0, 0, 1}, 6881},
        {{11, 0, 0, 2}, 6882},
        {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 9001},
        {{11, 0, 0, 3}, 7000}
      ],
      blocks: %{},
      productive: MapSet.new()
    }
  end

  @spec command_gen(model()) :: PropCheck.BasicTypes.type()
  def command_gen(%{hash: hash, endpoints: endpoints}) when endpoints != [] do
    pick = endpoint_pick(endpoints)

    frequency([
      {4, {:record, [hash, reason(), pick]}},
      {3, {:filter, [hash, min_count(), peer_subset(endpoints)]}},
      {2, {:mark_productive, [hash, pick]}},
      {2, {:blocked, [hash, pick]}}
    ])
  end

  @spec command_gen(model()) :: PropCheck.BasicTypes.type()
  def command_gen(%{hash: hash}) do
    {:record, [hash, :timeout, {127, 0, 0, 1}]}
  end

  defp reason do
    oneof([
      :timeout,
      :closed,
      :churn,
      :econnrefused,
      :handshake_timeout,
      :already_connected,
      :not_connectable,
      :socket_handoff_failed
    ])
  end

  defp min_count do
    oneof([0, 1, 2, 3])
  end

  defp endpoint_pick(endpoints), do: elements(endpoints)

  defp peer_subset(endpoints) do
    let eps <- resize(4, list(endpoint_pick(endpoints))) do
      eps
      |> Enum.uniq()
      |> Enum.map(fn {ip, port} -> %Peer{ip: ip, port: port} end)
    end
  end

  defcommand :record do
    @spec record(Torrent.hash(), atom(), endpoint()) :: :ok
    def record(hash, reason, {ip, port}) do
      :ok = DialBackoff.record(hash, ip, port, reason)
      _ = :sys.get_state(DialBackoff)
      :ok
    end

    @spec record_next(model(), [Torrent.hash() | atom() | endpoint()], :ok) :: model()
    def record_next(state, args, result), do: apply_record(state, args, result)

    @spec record_post(model(), [Torrent.hash() | atom() | endpoint()], :ok) :: boolean()
    def record_post(state, args, :ok) do
      expected = apply_record(state, args, :ok)

      case args do
        [_hash, _reason, {ip, port}] ->
          expected_blocked = Map.has_key?(expected.blocks, {ip, port})
          DialBackoff.blocked?(state.hash, ip, port) == expected_blocked
      end
    end
  end

  defp apply_record(state, [_hash, reason, ep], _result) do
    if reason in @non_reachability do
      state
    else
      key = ep
      prev = Map.get(state.blocks, key, %{fail_count: 0, sticky: false})
      fail_count = prev.fail_count + 1
      productive? = MapSet.member?(state.productive, key)

      sticky =
        cond do
          reason in @sticky_reasons -> true
          productive? and reason in @transient -> false
          fail_count >= @hard_fail_threshold and not productive? -> true
          true -> false
        end

      blocks = Map.put(state.blocks, key, %{fail_count: fail_count, sticky: sticky})
      %{state | blocks: blocks}
    end
  end

  defcommand :mark_productive do
    @spec mark_productive(Torrent.hash(), endpoint()) :: :ok
    def mark_productive(hash, {ip, port}) do
      :ok = DialBackoff.mark_productive(hash, ip, port)
      _ = :sys.get_state(DialBackoff)
      :ok
    end

    @spec mark_productive_next(model(), [Torrent.hash() | endpoint()], :ok) :: model()
    def mark_productive_next(state, [_hash, ep], _result) do
      state
      |> Map.update!(:productive, &MapSet.put(&1, ep))
      |> Map.update!(:blocks, &Map.delete(&1, ep))
    end

    @spec mark_productive_post(model(), [Torrent.hash() | endpoint()], :ok) :: boolean()
    def mark_productive_post(state, [_hash, {ip, port}], :ok) do
      DialBackoff.productive?(state.hash, ip, port) and
        not DialBackoff.blocked?(state.hash, ip, port)
    end
  end

  defcommand :blocked do
    @spec blocked(Torrent.hash(), endpoint()) :: boolean()
    def blocked(hash, {ip, port}) do
      DialBackoff.blocked?(hash, ip, port)
    end

    @spec blocked_post(model(), [Torrent.hash() | endpoint()], boolean()) :: boolean()
    def blocked_post(state, [_hash, {ip, port}], result) do
      is_boolean(result) and result == Map.has_key?(state.blocks, {ip, port})
    end
  end

  defcommand :filter do
    @spec filter(Torrent.hash(), non_neg_integer(), [Peer.t()]) :: [Peer.t()]
    def filter(hash, min_count, peers) do
      DialBackoff.filter(peers, hash, min_count)
    end

    @spec filter_post(
            model(),
            [Torrent.hash() | non_neg_integer() | [Peer.t()]],
            [Peer.t()]
          ) :: boolean()
    def filter_post(state, [_hash, min_count, peers], result) do
      if is_list(result) do
        expected = model_filter(state, peers, min_count)
        normalize_peers(result) == normalize_peers(expected)
      else
        false
      end
    end
  end

  @spec model_filter(model(), [Peer.t()], non_neg_integer()) :: [Peer.t()]
  defp model_filter(state, peers, min_count) do
    {allowed, blocked} = split_allowed_peers(state, peers)
    soft_blocked = filter_soft_blocked(state, blocked)
    resolve_filtered_peers(state, allowed, soft_blocked, min_count)
  end

  defp split_allowed_peers(state, peers) do
    Enum.split_with(peers, fn %Peer{ip: ip, port: port} ->
      not Map.has_key?(state.blocks, {ip, port})
    end)
  end

  defp filter_soft_blocked(state, blocked) do
    Enum.reject(blocked, fn %Peer{ip: ip, port: port} ->
      match?(%{sticky: true}, Map.get(state.blocks, {ip, port}))
    end)
  end

  defp resolve_filtered_peers(_state, allowed, _soft_blocked, min_count)
       when min_count <= 0 do
    allowed
  end

  defp resolve_filtered_peers(_state, allowed, soft_blocked, _min_count)
       when soft_blocked == [] do
    allowed
  end

  defp resolve_filtered_peers(_state, allowed, _soft_blocked, min_count)
       when length(allowed) >= min_count do
    allowed
  end

  defp resolve_filtered_peers(state, allowed, soft_blocked, min_count) do
    need = min(min_count - length(allowed), length(soft_blocked))
    allowed ++ take_soft(state, soft_blocked, need)
  end

  defp take_soft(_state, _blocked, 0), do: []

  defp take_soft(state, blocked, need) do
    {productive, rest} =
      Enum.split_with(blocked, fn %Peer{ip: ip, port: port} ->
        MapSet.member?(state.productive, {ip, port})
      end)

    {v6, v4} =
      Enum.split_with(rest, fn %Peer{ip: ip} ->
        tuple_size(ip) == 8
      end)

    productive
    |> Kernel.++(v6)
    |> Kernel.++(v4)
    |> Enum.take(need)
  end

  defp normalize_peers(peers) do
    peers
    |> Enum.map(fn %Peer{ip: ip, port: port} -> {ip, port} end)
    |> Enum.sort()
  end
end

defmodule Peer.ConnectionManager.QueueStateM do
  @moduledoc false
  use PropCheck
  use PropCheck.StateM.ModelDSL

  alias Peer.ConnectionManager.Queue, as: DialQueue

  @agent_key :queue_statem_sut_agent

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}
  @type model :: %{
          hash: Torrent.hash(),
          queue: DialQueue.t(),
          pex_sources: [binary()]
        }

  @spec initial_state() :: model()
  def initial_state do
    %{hash: <<0::160>>, queue: %{}, pex_sources: []}
  end

  @spec init(Torrent.hash()) :: model()
  def init(hash) when is_binary(hash) and byte_size(hash) == 20 do
    %{
      hash: hash,
      queue: %{},
      pex_sources: for(i <- 1..3, do: :binary.copy(<<i>>, 20))
    }
  end

  @spec register_sut_agent(pid()) :: :ok
  def register_sut_agent(pid) when is_pid(pid) do
    Process.put(@agent_key, pid)
    :ok
  end

  @spec unregister_sut_agent() :: :ok
  def unregister_sut_agent do
    Process.delete(@agent_key)
    :ok
  end

  defp sut_agent! do
    Process.get(@agent_key) ||
      raise ArgumentError, "QueueStateM SUT agent not registered in test process"
  end

  @spec command_gen(model()) :: PropCheck.BasicTypes.type()
  def command_gen(%{hash: hash, pex_sources: sources})
      when is_list(sources) and sources != [] do
    frequency([
      {3, {:offer_discovery, [hash, peer_batch()]}},
      {3, {:offer_pex, [hash, peer_batch(), elements(sources)]}},
      {2, {:revoke_pex, [endpoint_batch(), elements(sources)]}},
      {1, {:peers, [hash]}}
    ])
  end

  @spec command_gen(model()) :: PropCheck.BasicTypes.type()
  def command_gen(%{hash: hash}) do
    {:offer_discovery, [hash, []]}
  end

  defp peer_batch do
    resize(4, list(peer_gen()))
  end

  defp endpoint_batch do
    resize(3, list(endpoint_gen()))
  end

  defp peer_gen do
    let n <- integer(1, 200) do
      let port <- integer(7000, 65_535) do
        %Peer{ip: {11, 0, 0, rem(n, 250)}, port: port}
      end
    end
  end

  defp endpoint_gen do
    let n <- integer(1, 200) do
      let port <- integer(7000, 65_535) do
        {{11, 0, 0, rem(n, 250)}, port}
      end
    end
  end

  defcommand :offer_discovery do
    @spec offer_discovery(Torrent.hash(), [Peer.t()]) :: :ok
    def offer_discovery(hash, peers) do
      Agent.update(sut_agent!(), fn q -> DialQueue.offer(q, peers, :discovery, hash: hash) end)
      :ok
    end

    @spec offer_discovery_next(model(), [Torrent.hash() | [Peer.t()]], :ok) :: model()
    def offer_discovery_next(state, [_hash, peers], _result) do
      %{state | queue: DialQueue.offer(state.queue, peers, :discovery, hash: state.hash)}
    end

    @spec offer_discovery_post(model(), [Torrent.hash() | [Peer.t()]], :ok) :: boolean()
    def offer_discovery_post(state, [_hash, peers], _result) do
      expected = DialQueue.offer(state.queue, peers, :discovery, hash: state.hash)
      Agent.get(sut_agent!(), & &1) == expected
    end
  end

  defcommand :offer_pex do
    @spec offer_pex(Torrent.hash(), [Peer.t()], binary()) :: :ok
    def offer_pex(hash, peers, pex_src) do
      Agent.update(sut_agent!(), fn q ->
        DialQueue.offer(q, peers, {:pex, pex_src}, hash: hash)
      end)

      :ok
    end

    @spec offer_pex_next(model(), [Torrent.hash() | [Peer.t()] | binary()], :ok) :: model()
    def offer_pex_next(state, [_hash, peers, pex_src], _result) do
      %{
        state
        | queue: DialQueue.offer(state.queue, peers, {:pex, pex_src}, hash: state.hash)
      }
    end

    @spec offer_pex_post(model(), [Torrent.hash() | [Peer.t()] | binary()], :ok) :: boolean()
    def offer_pex_post(state, [_hash, peers, pex_src], _result) do
      expected =
        DialQueue.offer(state.queue, peers, {:pex, pex_src}, hash: state.hash)

      Agent.get(sut_agent!(), & &1) == expected
    end
  end

  defcommand :revoke_pex do
    @spec revoke_pex([Peer.t() | endpoint()], binary()) :: :ok
    def revoke_pex(endpoints, pex_src) do
      Agent.update(sut_agent!(), fn q -> DialQueue.revoke_pex(q, pex_src, endpoints) end)
      :ok
    end

    @spec revoke_pex_pre(model(), [[Peer.t() | endpoint()] | binary()]) :: boolean()
    def revoke_pex_pre(state, [endpoints, pex_src]) do
      Enum.any?(endpoints, fn ep ->
        key = if is_tuple(ep), do: ep, else: {ep.ip, ep.port}
        Map.has_key?(state.queue, key)
      end) and pex_src in state.pex_sources
    end

    @spec revoke_pex_next(model(), [[Peer.t() | endpoint()] | binary()], :ok) :: model()
    def revoke_pex_next(state, [endpoints, pex_src], _result) do
      %{state | queue: DialQueue.revoke_pex(state.queue, pex_src, endpoints)}
    end

    @spec revoke_pex_post(model(), [[Peer.t() | endpoint()] | binary()], :ok) :: boolean()
    def revoke_pex_post(state, [endpoints, pex_src], _result) do
      expected = DialQueue.revoke_pex(state.queue, pex_src, endpoints)
      Agent.get(sut_agent!(), & &1) == expected
    end
  end

  defcommand :peers do
    @spec peers(Torrent.hash()) :: [Peer.t()]
    def peers(_hash) do
      Agent.get(sut_agent!(), &DialQueue.peers/1)
    end

    @spec peers_next(model(), [Torrent.hash()], [Peer.t()]) :: model()
    def peers_next(state, _args, _result), do: state

    @spec peers_post(model(), [Torrent.hash()], [Peer.t()]) :: boolean()
    def peers_post(%{queue: model_q}, [_hash], result) do
      is_list(result) and normalize_peers(result) == normalize_peers(DialQueue.peers(model_q))
    end
  end

  defp normalize_peers(peers) do
    peers
    |> Enum.map(fn %Peer{ip: ip, port: port} -> {ip, port} end)
    |> Enum.sort()
  end
end

defmodule StateMachinesTest do
  use ExUnit.Case, async: false

  use PropCheck,
    default_opts: [
      :quiet,
      numtests: 12,
      max_size: 10
    ]

  import PropCheck.StateM.ModelDSL, only: [commands: 2, run_commands: 2]

  alias Peer.ConnectionManager.QueueStateM
  alias Peer.DialBackoffStateM

  @moduletag :state_machine
  @moduletag store_counter_example: false
  @tag timeout: 45_000

  setup do
    {:ok, _} = Application.ensure_all_started(:elixir_torrent)
    clear_dial_backoff_tables()
    :ok
  end

  property "Peer.DialBackoff record/filter/clear matches model" do
    hash = :crypto.strong_rand_bytes(20)
    init = DialBackoffStateM.init(hash)

    forall cmds <- commands(DialBackoffStateM, init) do
      clear_dial_backoff_tables()

      {_history, _state, result} = run_commands(DialBackoffStateM, cmds)

      clear_dial_backoff_tables()
      result == :ok
    end
  end

  property "Peer.ConnectionManager.Queue offer/revoke matches model" do
    forall cmds <-
             (let hash <- binary(20) do
                commands(
                  QueueStateM,
                  QueueStateM.init(hash)
                )
              end) do
      {:ok, agent} = Agent.start_link(fn -> %{} end)
      :ok = QueueStateM.register_sut_agent(agent)

      try do
        Agent.update(agent, fn _ -> %{} end)

        {_history, _state, result} = run_commands(QueueStateM, cmds)

        Agent.update(agent, fn _ -> %{} end)
        result == :ok
      after
        QueueStateM.unregister_sut_agent()
        Agent.stop(agent, :normal, 5_000)
      end
    end
  end

  defp clear_dial_backoff_tables do
    if :ets.info(:peer_dial_backoff) != :undefined do
      :ets.delete_all_objects(:peer_dial_backoff)
    end

    if :ets.info(:peer_dial_productive) != :undefined do
      :ets.delete_all_objects(:peer_dial_productive)
    end
  end
end
