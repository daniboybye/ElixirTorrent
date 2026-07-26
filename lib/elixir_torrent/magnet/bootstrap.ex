defmodule Magnet.Bootstrap do
  @moduledoc false

  use Supervisor

  require Logger

  alias Peer.LTEP.Session
  alias Torrent.{Model, Swarm}

  @spec ensure(Magnet.t()) :: :ok
  def ensure(%Magnet{} = magnet) do
    hash = magnet.hash

    case GenServer.whereis(via_name(hash)) do
      nil -> start_bootstrap(magnet)
      _pid -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @spec start_bootstrap(Magnet.t()) :: :ok
  defp start_bootstrap(%Magnet{} = magnet) do
    case DynamicSupervisor.start_child(Magnet.Bootstrap.Supervisor, {__MODULE__, magnet}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _} -> :ok
    end
  end

  @spec active?(Torrent.hash()) :: boolean()
  def active?(hash) when is_binary(hash) do
    case GenServer.whereis(via_name(hash)) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  @spec stop(Torrent.hash()) :: :ok
  def stop(hash) when is_binary(hash) do
    case GenServer.whereis(via_name(hash)) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(Magnet.Bootstrap.Supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
        end
    end
  catch
    :exit, _ -> :ok
  end

  @spec offer_peers(Torrent.hash(), [Peer.t()]) :: :ok
  def offer_peers(hash, peers) when is_binary(hash) and is_list(peers) do
    _ = Peer.ConnectionManager.offer_peers(hash, peers)
    _ = Peer.ConnectionManager.kick(hash)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec metadata_peer_keys(Torrent.hash()) :: [Peer.key()]
  def metadata_peer_keys(hash) when is_binary(hash) do
    hash
    |> Torrent.Swarm.peer_supervisors()
    |> Enum.flat_map(&metadata_key/1)
  catch
    :exit, _ -> []
  end

  @spec metadata_key(pid()) :: [Peer.key()]
  defp metadata_key(pid) when is_pid(pid) do
    with key when is_tuple(key) <- Peer.get_key(pid),
         {:ok, info} <- safe_metadata_capable(key) do
      if metadata_peer_candidate?(info) do
        [key]
      else
        log_metadata_skip(key, info, :not_eligible)
        []
      end
    else
      :error ->
        if key = Peer.get_key(pid), do: log_metadata_skip(key, nil, :no_ltep)
        []

      _ ->
        []
    end
  catch
    :exit, _ -> []
  end

  @spec safe_metadata_capable(Peer.key()) :: {:ok, map()} | :error
  defp safe_metadata_capable(key) do
    case Peer.Controller.metadata_capable(key) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  catch
    :exit, _ -> :error
  end

  @spec log_metadata_skip(Peer.key(), map() | nil, atom()) :: :ok
  defp log_metadata_skip(key, info, reason) do
    metadata_size = info && info.metadata_size
    seeder? = info && info.seeder?

    Logger.debug(
      "[magnet_swarm] metadata_peer_skip peer=#{Peer.log_key(key)} reason=#{reason} metadata_size=#{inspect(metadata_size)} seeder=#{inspect(seeder?)}"
    )
  end

  @spec metadata_peer_candidate?(map()) :: boolean()
  def metadata_peer_candidate?(info) when is_map(info) do
    Session.peer_supports?(info.ltep, Magnet.UtMetadata.extension_name())
  end

  @spec metadata_peer_eligible?(map()) :: boolean()
  def metadata_peer_eligible?(info) when is_map(info) do
    metadata_peer_candidate?(info) and
      ((is_integer(info.metadata_size) and info.metadata_size > 0) or info.seeder? == true)
  end

  @spec start_link(Magnet.t()) :: Supervisor.on_start()
  def start_link(%Magnet{} = magnet) do
    Supervisor.start_link(__MODULE__, magnet, name: via_name(magnet.hash))
  end

  @impl true
  def init(%Magnet{} = magnet) do
    hash = magnet.hash
    hash_hex = Torrent.hex_encoded_hash(hash)
    Logger.info("[magnet_swarm] bootstrap_start hash=#{hash_hex}")

    torrent = stub_torrent(magnet)
    :ok = Torrent.PiecesStatistic.init(torrent)

    children = [
      {Model, torrent},
      {Swarm, hash},
      {Peer.ConnectionManager, hash}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec stub_torrent(Magnet.t()) :: Torrent.t()
  defp stub_torrent(%Magnet{hash: hash, display_name: name}) do
    display =
      case name do
        n when is_binary(n) and n != "" -> URI.decode(n)
        _ -> Torrent.hex_encoded_hash(hash)
      end

    %Torrent{
      hash: hash,
      metadata: %{
        "info" => %{
          "name" => display,
          "piece length" => 16_384,
          "pieces" => <<0::160>>,
          "length" => Magnet.metadata_left()
        }
      },
      left: Magnet.metadata_left(),
      last_index: 0,
      last_piece_length: Magnet.metadata_left(),
      peer_status: :connecting_to_peers
    }
  end

  @spec via_name(Torrent.hash()) ::
          {:via, Registry, {Registry, {:magnet_bootstrap, Torrent.hash()}}}
  defp via_name(hash), do: {:via, Registry, {Registry, {:magnet_bootstrap, hash}}}
end
