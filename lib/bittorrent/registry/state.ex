defmodule Bittorrent.Registry.State do
  defstruct torrent_names: %{}, loading_torrents: %{}

  @type t :: %__MODULE__{
          torrent_names: %{binary() => {pid(), pid()}},
          loading_torrents: %{pid() => {GenServer.from(), pid()}}
        }

  @type message :: :error | {:error, any()} | binary()

  #@spec load(__MODULE__.t(), GenServer.from(), binary()) :: __MODULE__.t()
  def load(%__MODULE__{loading_torrents: loading_torrents} = state, from, torrent_name) do
    with {:ok, torrent} <-
      DynamicSupervisor.start_child(
        Bittorrent.Torrents,
        {Bittorrent.Torrent, torrent_name) 
      ) do
    {[{_, swarm, _, _}], [{_, server, _, _}]} =
      torrent
      |> Supervisor.which_children()
      |> Enum.split_with(fn {_, _, x, _} -> x === :supervisor end)
    GenServer.cast(server, {:start, torrent_name})

    loading_torrents
    |> Map.put(server, {from, torrent})
    |> (&%__MODULE__{state | loading_torrents: &1}).()
    else
      _ -> :error
    end
  end

  @spec handle_load(__MODULE__.t(), {pid(), message()}) :: __MODULE__.t()
  def handle_load(%__MODULE__{} = state, {pid, :error} = message) when is_pid(pid) do
    not_load(state, message)
  end

  def handle_load(%__MODULE__{} = state, {pid, {:error, _}} = message) when is_pid(pid) do
    not_load(state, message)
  end

  def handle_load(
        %__MODULE__{torrent_names: torrent_names, loading_torrents: loading_torrents},
        {pid_genserver, torrent_name}
      )
      when is_pid(pid_genserver) and is_binary(torrent_name) do
    {{from, pid_supervisor}, new_map} = Map.pop(loading_torrents, pid_genserver)
    GenServer.reply(from, {:ok, torrent_name})

    torrent_names
    |> Map.put(torrent_name, {pid_supervisor, pid_genserver})
    |> (&%__MODULE__{torrent_names: &1, loading_torrents: new_map}).()
  end

  defp not_load(%__MODULE__{loading_torrents: loading_torrents} = state, {pid, message}) do
    {{from, pid_supervisor}, new_map} = Map.pop(loading_torrents, pid)
    DynamicSupervisor.terminate_child(BittorrentClient.DynamicSupervisor, pid_supervisor)
    GenServer.reply(from, message)

    %__MODULE__{state | loading_torrents: new_map}
  end
end
