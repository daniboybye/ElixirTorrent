defmodule Torrent.Uploader do
  @moduledoc """
  Task supervisor serving inbound BEP 3 `piece` uploads from disk for one torrent.
  """

  use Via

  alias Torrent.{FileHandle, Model}

  require Logger

  @spec child_spec(Torrent.hash()) :: Supervisor.child_spec()
  def child_spec(hash) do
    %{
      start: {Task.Supervisor, :start_link, [[max_restarts: 0, name: via(hash)]]},
      type: :supervisor,
      restart: :transient,
      id: __MODULE__
    }
  end

  @spec request(
          Torrent.hash(),
          Peer.id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length(),
          (iodata() -> any())
        ) :: DynamicSupervisor.on_start_child()
  def request(hash, peer_id, index, begin, length, callback) do
    Task.Supervisor.start_child(
      via(hash),
      fn ->
        name = {begin, length, index, peer_id, hash}
        Registry.register(Registry, name, nil)

        {:ok, block} = FileHandle.read(hash, index, begin, length)

        case deliver_callback(callback, block) do
          :cancelled -> :ok
          _ -> Model.uploaded_subpiece(hash, length)
        end
      end
    )
  end

  # The peer this block is for can disappear at any point: it disconnects, trips
  # a protocol error, or its supervisor shuts it down. The callback is a
  # `GenServer.call` into that peer, so it then exits with the peer's reason.
  # Sending a block to a peer that is gone is moot rather than a fault — before
  # this only `:noproc` was tolerated, so one peer dying with `:protocol_error`
  # while it had requests outstanding logged 87 `[error]` task crashes at once.
  # Anything that is not the peer going away is still allowed to crash the task.
  @spec deliver_callback((iodata() -> any()), iodata()) :: any()
  defp deliver_callback(callback, block) do
    callback.(block)
  catch
    :exit, reason ->
      if undeliverable?(reason), do: cancel_upload(reason), else: exit(reason)
  end

  # Reasons that mean "this block is never reaching that peer". Anything else
  # still crashes the task, so a genuine fault in the delivery path is not
  # swallowed. A timeout counts: the peer's controller could not accept the
  # block within the call timeout, which in practice is a peer whose socket has
  # stopped draining. BEP 3 lets us simply not answer a request — it will ask
  # again if it still wants the block.
  @spec undeliverable?(term()) :: boolean()
  defp undeliverable?(:noproc), do: true
  defp undeliverable?(:normal), do: true
  defp undeliverable?(:shutdown), do: true
  defp undeliverable?(:timeout), do: true
  defp undeliverable?({:shutdown, _reason}), do: true
  # `GenServer.call/3` wraps the callee's exit reason as `{reason, call_info}`.
  defp undeliverable?({reason, _call}), do: undeliverable?(reason)
  defp undeliverable?(_), do: false

  # One debug line rather than a task crash dump. A slow peer with a deep
  # request queue produced 333 `[error]` reports in fifteen minutes — all the
  # same fact, repeated once per in-flight block.
  defp cancel_upload(reason) do
    Logger.debug("[peer_upload] deliver_cancelled reason=#{inspect(unwrap_reason(reason))}")
    :cancelled
  end

  defp unwrap_reason({reason, _call}), do: reason
  defp unwrap_reason(reason), do: reason

  @spec cancel(
          Torrent.hash(),
          Peer.id(),
          Torrent.begin(),
          Torrent.index(),
          Torrent.length()
        ) :: :ok
  def cancel(hash, peer_id, index, begin, length) do
    name = {begin, length, index, peer_id, hash}

    with [{task, nil}] <- Registry.lookup(Registry, name),
         do: Task.Supervisor.terminate_child(via(hash), task)

    :ok
  end
end
