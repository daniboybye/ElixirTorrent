defmodule Acceptor.Connection do
  alias __MODULE__.{Handler, Handshakes}

  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [[Handler, Handshakes], [strategy: :rest_for_one]]}
    }
  end
end
