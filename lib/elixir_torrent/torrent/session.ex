defmodule Torrent.Session do
  @moduledoc false

  @spec dir() :: Path.t()
  def dir do
    Path.join([File.cwd!(), ".elixir_torrent", "state"])
  end

  @spec path(Torrent.hash()) :: Path.t()
  def path(hash) do
    Path.join(dir(), Torrent.hex_encoded_hash(hash) <> ".term")
  end

  @spec save(Torrent.hash(), Torrent.t()) :: :ok
  def save(hash, %Torrent{} = torrent) do
    File.mkdir_p!(dir())

    payload = %{
      bitfield: torrent.bitfield,
      downloaded: torrent.downloaded,
      left: torrent.left,
      uploaded: torrent.uploaded,
      added_at: torrent.added_at,
      peer_status: torrent.peer_status
    }

    hash
    |> path()
    |> then(&File.write!(&1, :erlang.term_to_binary(payload)))
  end

  @spec load(Torrent.hash()) :: {:ok, map()} | :error
  def load(hash) do
    hash
    |> path()
    |> then(fn file ->
      if File.regular?(file) do
        file
        |> File.read!()
        |> :erlang.binary_to_term()
        |> then(&{:ok, &1})
      else
        :error
      end
    end)
  rescue
    _ -> :error
  end

  @spec delete(Torrent.hash()) :: :ok
  def delete(hash) do
    case path(hash) do
      file when is_binary(file) ->
        case File.rm(file) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec apply(Torrent.t(), map()) :: Torrent.t()
  def apply(%Torrent{} = torrent, session) when is_map(session) do
    %{
      torrent
      | bitfield: Map.get(session, :bitfield) || torrent.bitfield,
        downloaded: Map.get(session, :downloaded, torrent.downloaded),
        left: Map.get(session, :left, torrent.left),
        uploaded: Map.get(session, :uploaded, torrent.uploaded),
        added_at: Map.get(session, :added_at, torrent.added_at),
        peer_status: Map.get(session, :peer_status, torrent.peer_status)
    }
  end
end
