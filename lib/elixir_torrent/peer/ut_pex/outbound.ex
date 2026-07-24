defmodule Peer.UtPex.Outbound do
  @moduledoc false

  alias Peer.UtPex.{BEP40, Entry, Filter, RecentCache}

  @doc """
  Builds the eligible outbound map for one connection: live swarm snapshot plus optional
  recent-list supplement, ordered by BEP 40 for stable encoding.
  """
  @spec prepare_current(
          Torrent.hash(),
          %{Entry.endpoint() => Entry.t()},
          keyword()
        ) :: {%{Entry.endpoint() => Entry.t()}, [Entry.endpoint()]}
  def prepare_current(hash, live_current, opts \\ []) when is_map(live_current) do
    self_ep = Keyword.get(opts, :self_ep)
    clients = client_refs(Keyword.get(opts, :state))

    filtered =
      live_current
      |> Map.delete(self_ep)
      |> Enum.filter(fn {ep, _} -> Filter.advertisable?(hash, ep, self_ep) end)
      |> Map.new()

    {augmented, drained} =
      if Keyword.get(opts, :supplement_recent?, false) do
        RecentCache.supplement(hash, filtered,
          self_ep: self_ep,
          clients: clients,
          now_ms: Keyword.get(opts, :now_ms),
          drain?: Keyword.get(opts, :drain_recent?, false)
        )
      else
        {filtered, []}
      end

    ordered = order_entries(augmented, clients)
    {Map.new(ordered, &{Entry.endpoint(&1), &1}), drained}
  end

  @doc false
  @spec order_entries([Entry.t()] | map(), term()) :: [Entry.t()]
  def order_entries(entries, clients) when is_map(entries),
    do: order_entries(Map.values(entries), clients)

  def order_entries(entries, clients) when is_list(entries) do
    v4 = Enum.filter(entries, fn %Entry{ip: ip} -> tuple_size(ip) == 4 end)
    v6 = Enum.filter(entries, fn %Entry{ip: ip} -> tuple_size(ip) == 8 end)

    order_family(v4, Map.get(clients, :inet)) ++
      order_family(v6, Map.get(clients, :inet6))
  end

  @doc false
  @spec order_endpoints([Entry.endpoint()], clients()) :: [Entry.endpoint()]
  def order_endpoints(endpoints, clients) do
    v4 = Enum.filter(endpoints, &(tuple_size(elem(&1, 0)) == 4))
    v6 = Enum.filter(endpoints, &(tuple_size(elem(&1, 0)) == 8))

    order_endpoint_family(v4, Map.get(clients, :inet)) ++
      order_endpoint_family(v6, Map.get(clients, :inet6))
  end

  @spec order_family([Entry.t()], term()) :: [Entry.t()]
  defp order_family(entries, client) when is_tuple(client) do
    endpoints = Enum.map(entries, &Entry.endpoint/1)
    ordered_eps = BEP40.sort_peers(client, endpoints)
    by_ep = Map.new(entries, &{Entry.endpoint(&1), &1})
    Enum.map(ordered_eps, &Map.fetch!(by_ep, &1))
  end

  defp order_family(entries, _client), do: Enum.sort_by(entries, &Entry.endpoint/1)

  @spec order_endpoint_family([Entry.endpoint()], Peer.UtPex.BEP40.client() | nil) ::
          [Entry.endpoint()]
  defp order_endpoint_family(endpoints, client) when is_tuple(client),
    do: BEP40.sort_peers(client, endpoints)

  defp order_endpoint_family(endpoints, _client), do: Enum.sort(endpoints)

  @type clients :: %{
          inet: Peer.UtPex.BEP40.client() | nil,
          inet6: Peer.UtPex.BEP40.client() | nil
        }

  @doc false
  @spec client_refs(Peer.Controller.State.t() | nil) :: clients()
  def client_refs(nil), do: local_client_refs()

  def client_refs(%Peer.Controller.State{} = state) do
    refs = local_client_refs()
    port = Application.get_env(:elixir_torrent, :listen_port, 6881)

    case yourip_from_ltep(state) do
      {:ok, ip} ->
        Map.put(refs, family(ip), {ip, port})

      :error ->
        refs
    end
  end

  @spec yourip_from_ltep(Peer.Controller.State.t()) :: {:ok, :inet.ip_address()} | :error
  defp yourip_from_ltep(%Peer.Controller.State{ltep: ltep}) when not is_nil(ltep) do
    case Peer.LTEP.Session.peer_handshake(ltep).yourip do
      <<a, b, c, d>> ->
        validate_yourip({a, b, c, d})

      <<s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16>> ->
        validate_yourip({s1, s2, s3, s4, s5, s6, s7, s8})

      _ ->
        :error
    end
  end

  defp yourip_from_ltep(_), do: :error

  @spec validate_yourip(:inet.ip_address()) :: {:ok, :inet.ip_address()} | :error
  defp validate_yourip(ip) do
    if Filter.global_unicast_ip?(ip), do: {:ok, ip}, else: :error
  end

  @spec local_client_refs() :: clients()
  defp local_client_refs do
    ips = Acceptor.primary_ips()
    port = Application.get_env(:elixir_torrent, :listen_port, 6881)

    %{
      inet: if(is_tuple(ips.inet), do: {ips.inet, port}),
      inet6: if(is_tuple(ips.inet6), do: {ips.inet6, port})
    }
  end

  @spec family(:inet.ip_address()) :: :inet | :inet6
  defp family(ip) do
    case tuple_size(ip) do
      4 -> :inet
      8 -> :inet6
    end
  end
end
