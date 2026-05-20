defmodule Magnet.Fetcher.Supervisor do
  @moduledoc false

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {
        DynamicSupervisor,
        :start_link,
        [[name: __MODULE__, strategy: :one_for_one, max_restarts: 0]]
      }
    }
  end
end
