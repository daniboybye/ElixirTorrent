defmodule Peer.UtPex.Filter do
  @moduledoc false

  alias Acceptor.Connection.Handshakes

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}

  @doc """
  True when an endpoint may be advertised in outbound PEX or ingested from a remote peer.
  Stricter than dial `connectable?` — global unicast only.
  """
  @spec global_unicast_endpoint?(endpoint()) :: boolean()
  def global_unicast_endpoint?({ip, port}) do
    global_unicast_ip?(ip) and is_integer(port) and port > 0 and port <= 65_535
  end

  @doc false
  @spec advertisable?(Torrent.hash(), endpoint(), endpoint() | nil) :: boolean()
  def advertisable?(hash, endpoint, self_ep \\ nil) do
    global_unicast_endpoint?(endpoint) and endpoint != self_ep and
      not Handshakes.local_endpoint?(
        elem(endpoint, 0),
        elem(endpoint, 1),
        listen_port(hash)
      )
  end

  @doc false
  @spec filter_peers([Peer.t()], Torrent.hash()) :: [Peer.t()]
  def filter_peers(peers, hash) when is_list(peers) do
    lp = listen_port(hash)

    Enum.filter(peers, fn %Peer{ip: ip, port: port} ->
      global_unicast_endpoint?({ip, port}) and
        not Handshakes.local_endpoint?(ip, port, lp)
    end)
  end

  @doc """
  When the queue already holds another port for the same IP, keep the existing entry.
  """
  @spec duplicate_ip_blocked?(Peer.ConnectionManager.Queue.t(), Peer.t()) :: boolean()
  def duplicate_ip_blocked?(queue, %Peer{ip: ip, port: port}) when is_map(queue) do
    Enum.any?(queue, fn {{qip, qport}, _} ->
      qip == ip and qport != port
    end)
  end

  @spec listen_port(Torrent.hash()) :: :inet.port_number()
  defp listen_port(_hash), do: Application.get_env(:elixir_torrent, :listen_port, 6881)

  @spec global_unicast_ip?(:inet.ip_address()) :: boolean()
  def global_unicast_ip?({0, _, _, _}), do: false
  def global_unicast_ip?({127, _, _, _}), do: false
  def global_unicast_ip?({10, _, _, _}), do: false
  def global_unicast_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: false
  def global_unicast_ip?({192, 168, _, _}), do: false
  def global_unicast_ip?({169, 254, _, _}), do: false
  def global_unicast_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: false
  def global_unicast_ip?({192, 0, 0, _}), do: false
  def global_unicast_ip?({192, 0, 2, _}), do: false
  def global_unicast_ip?({198, 18, _, _}), do: false
  def global_unicast_ip?({198, 19, _, _}), do: false
  def global_unicast_ip?({198, 51, 100, _}), do: false
  def global_unicast_ip?({203, 0, 113, _}), do: false
  def global_unicast_ip?({a, _, _, _}) when a >= 224 and a <= 239, do: false
  def global_unicast_ip?({a, _, _, _}) when a >= 240, do: false

  def global_unicast_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  def global_unicast_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def global_unicast_ip?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false
  def global_unicast_ip?({0x100, 0, 0, 0, _, _, _, _}), do: false
  def global_unicast_ip?({0x2001, 0xDB8, _, _, _, _, _, _}), do: false
  def global_unicast_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: false
  def global_unicast_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: false
  def global_unicast_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false

  def global_unicast_ip?({_, _, _, _}), do: true
  def global_unicast_ip?({a, _, _, _, _, _, _, _}) when a >= 0x2000 and a <= 0x3FFF, do: true
  def global_unicast_ip?({_, _, _, _, _, _, _, _}), do: false
  def global_unicast_ip?(_), do: false
end
