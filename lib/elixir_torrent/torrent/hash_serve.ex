defmodule Torrent.HashServe do
  @moduledoc """
  Disk-backed BEP 52 hash request serving for a torrent.

  Work runs under a per-torrent `Task.Supervisor` so `Peer.Controller` never
  blocks on file I/O while answering inbound `hash_request` messages.
  """

  use Via

  alias Peer.{HashWire, Sender}
  alias Torrent.{FileHandle, Merkle}

  @max_tasks 8

  def child_spec(hash) do
    %{
      start:
        {Task.Supervisor, :start_link,
         [[max_restarts: 0, max_children: @max_tasks, name: via(hash)]]},
      type: :supervisor,
      restart: :transient,
      id: __MODULE__
    }
  end

  @type response :: {:hashes, [Merkle.hash()]} | :reject

  @doc """
  Validates and serves a hash request asynchronously.

  `sender_key` pins the reply to the current connection; stale tasks after a
  reconnect with the same registry key are ignored. On task start failure the
  callback receives `:reject` immediately.
  """
  @spec serve(Torrent.hash(), HashWire.t(), Peer.key(), (response() -> any())) :: :ok
  def serve(hash, %HashWire{} = req, sender_key, callback) when is_function(callback, 1) do
    sender_pid = sender_pid(sender_key)

    try do
      case Task.Supervisor.start_child(via(hash), fn ->
             result = do_serve(hash, req)
             maybe_deliver(sender_key, sender_pid, callback, result)
           end) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          maybe_deliver(sender_key, sender_pid, callback, :reject)
          :ok
      end
    catch
      :exit, _ ->
        maybe_deliver(sender_key, sender_pid, callback, :reject)
        :ok
    end
  end

  @doc false
  @spec num_layers_for_file(non_neg_integer()) :: pos_integer()
  def num_layers_for_file(file_length) when is_integer(file_length) and file_length > 0 do
    Merkle.merkle_num_layers(Merkle.file_block_count(file_length))
  end

  @spec do_serve(Torrent.hash(), HashWire.t()) :: response()
  defp do_serve(hash, req) do
    with {:ok, ctx} <- fetch_context(hash),
         {:ok, piece_layer} <- Merkle.piece_layer_level(ctx.piece_length),
         :ok <- HashWire.validate_request(req, piece_layer),
         {:ok, file} <- find_file(ctx, req.pieces_root),
         num_layers <- num_layers_for_file(file.length),
         :ok <- HashWire.validate_response_header(req, piece_layer, num_layers),
         :ok <- validate_index_bounds(file, req, ctx.piece_length) do
      serve_file(ctx, file, req, piece_layer)
    else
      _ -> :reject
    end
  catch
    _, _ -> :reject
  end

  @spec maybe_deliver(Peer.key(), pid() | nil, (response() -> any()), response()) :: :ok
  defp maybe_deliver(sender_key, sender_pid, callback, result) do
    if sender_pid != nil and sender_pid == sender_pid(sender_key) do
      callback.(result)
    end

    :ok
  end

  @spec sender_pid(Peer.key()) :: pid() | nil
  defp sender_pid(sender_key) do
    GenServer.whereis({:via, Registry, {Registry, {sender_key, Sender}}})
  end

  @doc false
  @spec max_tasks() :: pos_integer()
  def max_tasks, do: @max_tasks

  @doc false
  @spec validate_outbound(Torrent.hash(), HashWire.t()) :: :ok | {:error, term()}
  def validate_outbound(hash, %HashWire{} = req) do
    with {:ok, ctx} <- fetch_context(hash),
         {:ok, piece_layer} <- Merkle.piece_layer_level(ctx.piece_length),
         :ok <- HashWire.validate_request(req, piece_layer),
         {:ok, file} <- find_file(ctx, req.pieces_root) do
      num_layers = num_layers_for_file(file.length)

      with :ok <- HashWire.validate_response_header(req, piece_layer, num_layers) do
        validate_index_bounds(file, req, ctx.piece_length)
      end
    end
  end

  @spec fetch_context(Torrent.hash()) :: {:ok, map()} | {:error, :missing_v2_context}
  defp fetch_context(hash) do
    case FileHandle.context(hash) do
      %{v2_merkle: %{piece_length: _}, piece_length: _} = ctx -> {:ok, ctx}
      _ -> {:error, :missing_v2_context}
    end
  end

  @spec find_file(map(), Merkle.hash()) ::
          {:ok, Merkle.file_context()} | {:error, :unknown_pieces_root}
  defp find_file(%{v2_merkle: %{files: files}}, root) do
    case Enum.find(files, &(&1.pieces_root == root)) do
      nil -> {:error, :unknown_pieces_root}
      file -> {:ok, file}
    end
  end

  @spec validate_index_bounds(Merkle.file_context(), HashWire.t(), pos_integer()) ::
          :ok | {:error, :invalid_index}
  defp validate_index_bounds(%{length: 0}, _req, _piece_length), do: {:error, :invalid_index}

  defp validate_index_bounds(%{length: length}, %{base_layer: 0} = req, _piece_length) do
    block_count = Merkle.file_block_count(length)

    if req.index + req.length <= block_count,
      do: :ok,
      else: {:error, :invalid_index}
  end

  defp validate_index_bounds(%{piece_hashes: nodes}, req, _piece_length) do
    if req.index + req.length <= length(nodes),
      do: :ok,
      else: {:error, :invalid_index}
  end

  @spec serve_file(map(), Merkle.file_context(), HashWire.t(), non_neg_integer()) ::
          response()
  defp serve_file(ctx, file, req, piece_layer) do
    cond do
      req.base_layer == piece_layer ->
        serve_piece_layer(file, req, piece_layer)

      req.base_layer == 0 ->
        serve_leaf_layer(ctx, file, req, ctx.piece_length)

      true ->
        :reject
    end
  end

  @spec serve_piece_layer(Merkle.file_context(), HashWire.t(), non_neg_integer()) ::
          response()
  defp serve_piece_layer(%{pieces_root: root, piece_hashes: nodes}, req, piece_layer) do
    if length(nodes) < 2 do
      :reject
    else
      case Merkle.range_response_from_layer(
             nodes,
             piece_layer,
             root,
             req.index,
             req.length,
             req.proof_layers
           ) do
        {:ok, hashes} -> {:hashes, hashes}
        _ -> :reject
      end
    end
  end

  @spec serve_leaf_layer(map(), Merkle.file_context(), HashWire.t(), pos_integer()) ::
          response()
  defp serve_leaf_layer(ctx, file, req, piece_length) do
    with {:ok, path} <- file_path(ctx, file),
         {:ok, hashes} <-
           Merkle.leaf_range_response_from_disk(
             path,
             file.length,
             file.piece_hashes,
             piece_length,
             req.index,
             req.length,
             req.proof_layers
           ) do
      {:hashes, hashes}
    else
      _ -> :reject
    end
  end

  @spec file_path(map(), Merkle.file_context()) :: {:ok, Path.t()} | {:error, term()}
  defp file_path(ctx, %{path: path, length: length}) do
    relative = path |> Path.join() |> String.replace("\\", "/")

    case Enum.find(ctx.all_files, fn
           {_end, {:gap, _}} ->
             false

           {_end, {name, len}} ->
             len == length and path_suffix?(name, relative)
         end) do
      {_end, {name, _}} -> {:ok, name}
      nil -> {:error, :missing_file}
    end
  end

  defp path_suffix?(full, relative) do
    full
    |> String.replace("\\", "/")
    |> String.ends_with?(relative)
  end
end
