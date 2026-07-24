defmodule Peer.UtPex.Entry do
  @moduledoc false

  @enforce_keys [:ip, :port]
  defstruct [:ip, :port, flags: 0]

  @type t :: %__MODULE__{
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          flags: byte()
        }

  @spec endpoint(t()) :: {:inet.ip_address(), :inet.port_number()}
  def endpoint(%__MODULE__{ip: ip, port: port}), do: {ip, port}

  @spec new({:inet.ip_address(), :inet.port_number()}, byte()) :: t()
  def new({ip, port}, flags \\ 0) when is_integer(flags) and flags >= 0 and flags <= 255 do
    %__MODULE__{ip: ip, port: port, flags: flags}
  end

  @doc false
  @spec normalize(Peer.UtPex.entry_input()) :: t()
  def normalize(%__MODULE__{} = entry), do: entry

  def normalize({ip, port}) when is_tuple(ip) and is_integer(port), do: new({ip, port}, 0)
end
