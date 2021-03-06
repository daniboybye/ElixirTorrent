defmodule Torrent do
  use Supervisor, type: :supervisor, restart: :transient
  use Via

  @type hash :: <<_::160>>
  @type index :: non_neg_integer()
  @type begin :: non_neg_integer()
  @type length :: pos_integer()
  @type block :: iodata()
  @type bitfield :: binary()
  @type speed :: %{:download => non_neg_integer(), :upload => non_neg_integer()}

  @empty 0
  @completed 1
  @started 2
  @stopped 3

  @enforce_keys [:hash, :metadata, :left, :last_index, :last_piece_length]
  defstruct [
    :hash,
    :metadata,
    :left,
    :last_index,
    :last_piece_length,
    bitfield: nil,
    peer_status: nil,
    uploaded: 0,
    downloaded: 0,
    event: @started,
    speed: %{download: 0, upload: 0}
  ]

  @type t :: %__MODULE__{
          # urlencoded 20-byte string used as a unique ID for the client, 
          # generated by the client at startup
          hash: hash(),
          metadata: map(),
          # The number of bytes this client still has to download in base
          # ten ASCII. Clarification: 
          # The number of bytes needed to download to be 100% complete 
          # and get all the included files in the torrent.
          left: non_neg_integer(),
          last_index: index(),
          last_piece_length: length(),
          peer_status: Peer.status(),
          # The total amount uploaded 
          # (since the client sent the 'started' event to the tracker)"""
          uploaded: non_neg_integer(),
          # The total amount downloaded 
          # (since the client sent the 'started' event to the tracker)"""
          downloaded: non_neg_integer(),
          # "started" | "empty" | "completed" | "stopped"
          event: 0..3,
          speed: speed(),
          bitfield: bitfield() | nil
        }

  alias __MODULE__.{
    Controller,
    Swarm,
    # Bitfield,
    PiecesStatistic,
    FileHandle,
    Uploader,
    Downloads,
    Model
  }

  @spec start_link(Path.t()) :: Supervisor.on_start() | none()
  def start_link(path),
    do: Supervisor.start_link(__MODULE__, path)

  @compile {:inline, empty: 0, started: 0, completed: 0, stopped: 0, event_to_string: 1}

  def started(), do: @started

  def empty(), do: @empty

  def completed(), do: @completed

  def stopped(), do: @stopped

  @spec event_to_string(0..3) :: String.t()
  def event_to_string(@empty), do: "empty"

  def event_to_string(@completed), do: "completed"

  def event_to_string(@started), do: "started"

  def event_to_string(@stopped), do: "stopped"

  def hex_encoded_hash(hash) do
    hash
    |> :crypto.bytes_to_integer()
    |> Integer.to_string(16)
    |> String.pad_leading(byte_size(hash) * 2, "0")
  end

  defdelegate has_hash?(hash), to: Model

  defdelegate add_peer(hash, id, reserved, socket), to: Swarm, as: :add

  defdelegate have?(hash, index), to: PiecesStatistic

  defdelegate get(hash), to: Model

  defdelegate get(hash, key), to: Model

  defdelegate downloaded?(hash), to: Model

  @spec get_hash(pid()) :: Torrent.hash() | nil
  def get_hash(pid) do
    case Registry.lookup(Registry, pid) do
      [{_, hash}] ->
        hash

      _ ->
        nil
    end
  end

  defdelegate stop(pid), to: Supervisor

  def init(path) do
    %Torrent{hash: hash} = torrent = parse_file!(path)

    PiecesStatistic.init(torrent)

    children = [
      {Model, torrent},
      {FileHandle, hash},
      {Uploader, hash},
      {Downloads, hash},
      {Swarm, hash},
      {Controller, hash}
    ]

    opts = [strategy: :one_for_all, max_restarts: 3]

    return = Supervisor.init(children, opts)

    Registry.register(Registry, self(), hash)
    PeerDiscovery.register(self(), torrent)

    return
  end

  @spec parse_file!(Path.t()) :: t() | no_return()
  def parse_file!(path) do
    metadata =
      path
      |> File.read!()
      |> Bento.decode!()

    bytes = all_bytes_in_torrent(metadata)

    last_index =
      metadata["info"]["pieces"]
      |> byte_size()
      |> div(20)
      |> Kernel.-(1)

    %__MODULE__{
      hash: info_hash(metadata),
      left: bytes,
      last_piece_length: bytes - last_index * metadata["info"]["piece length"],
      metadata: metadata,
      last_index: last_index
    }
  end

  defp info_hash(%{"info" => info}) do
    info
    |> Bento.encode!()
    |> (&:crypto.hash(:sha, &1)).()
  end

  defp all_bytes_in_torrent(%{"info" => %{"length" => length}}), do: length

  defp all_bytes_in_torrent(%{"info" => %{"files" => list}}),
    do: Enum.reduce(list, 0, fn %{"length" => x}, acc -> x + acc end)
end
