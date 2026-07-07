defmodule DHT.KRPC do
  @moduledoc """
  BEP 5 § KRPC Protocol — bencoded UDP RPC messages (query / response / error).

  Every message carries transaction id `t` and type `y` (`q`, `r`, or `e`). Queries
  add method `q` and arguments `a`; responses add return values `r`; errors add `e`.
  """

  alias DHT.Compact

  @type transaction_id :: binary()
  @type node_id :: <<_::160>>
  @type info_hash :: Torrent.hash()
  @type method :: :ping | :find_node | :get_peers | :announce_peer

  @type query :: %{
          required(:method) => method(),
          required(:transaction_id) => transaction_id(),
          required(:node_id) => node_id(),
          optional(:target) => node_id(),
          optional(:info_hash) => info_hash(),
          optional(:port) => :inet.port_number(),
          optional(:token) => binary(),
          optional(:implied_port) => 0 | 1,
          optional(:version) => binary()
        }

  @type response :: %{
          required(:transaction_id) => transaction_id(),
          required(:node_id) => node_id(),
          optional(:nodes) => binary(),
          optional(:values) => [binary()],
          optional(:token) => binary(),
          optional(:version) => binary()
        }

  @type error_response :: %{
          required(:transaction_id) => transaction_id(),
          required(:code) => 201..204,
          required(:message) => String.t(),
          optional(:version) => binary()
        }

  @doc "BEP 5 § KRPC — encode a query packet."
  @spec encode_query(query()) :: binary()
  def encode_query(%{method: method, transaction_id: tid, node_id: node_id} = query) do
    args =
      query
      |> query_args(method)
      |> Map.put("id", node_id)

    envelope = %{
      "t" => tid,
      "y" => "q",
      "q" => Atom.to_string(method),
      "a" => args
    }

    envelope
    |> maybe_put_version(query)
    |> Bento.encode!()
  end

  @doc "BEP 5 § KRPC — encode a successful response packet."
  @spec encode_response(response()) :: binary()
  def encode_response(%{transaction_id: tid, node_id: node_id} = response) do
    body =
      response
      |> Map.take([:nodes, :values, :token])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn
        {:nodes, nodes} -> {"nodes", nodes}
        {:values, values} -> {"values", values}
        {:token, token} -> {"token", token}
      end)
      |> Map.put("id", node_id)

    envelope = %{"t" => tid, "y" => "r", "r" => body}

    envelope
    |> maybe_put_version(response)
    |> Bento.encode!()
  end

  @doc "BEP 5 § KRPC — encode an error packet (`e: [code, message]`)."
  @spec encode_error(error_response()) :: binary()
  def encode_error(%{transaction_id: tid, code: code, message: message} = error) do
    envelope = %{"t" => tid, "y" => "e", "e" => [code, message]}

    envelope
    |> maybe_put_version(error)
    |> Bento.encode!()
  end

  @doc "BEP 5 § KRPC — decode any KRPC packet; malformed input returns `{:error, reason}`."
  @spec decode(binary()) ::
          {:ok, {:query, query()} | {:response, response()} | {:error, error_response()}}
          | {:error, term()}
  def decode(packet) when is_binary(packet) do
    with {:ok, map} <- Bento.decode(packet),
         {:ok, tid} <- fetch_binary(map, "t"),
         {:ok, type} <- fetch_type(map) do
      decode_typed(type, map, tid)
    else
      {:error, _} = error -> error
      _ -> {:error, :malformed}
    end
  end

  @spec decode_typed(String.t(), map(), binary()) ::
          {:ok, {:query, query()} | {:response, response()} | {:error, error_response()}}
          | {:error, term()}
  defp decode_typed("q", map, tid) do
    with {:ok, method} <- fetch_method(map["q"]),
         {:ok, args} <- fetch_map(map, "a"),
         {:ok, node_id} <- fetch_node_id(args["id"]) do
      query =
        %{
          method: method,
          transaction_id: tid,
          node_id: node_id,
          version: map["v"]
        }
        |> merge_query_args(method, args)

      {:ok, {:query, query}}
    else
      {:error, _} = error -> error
    end
  end

  defp decode_typed("r", map, tid) do
    with {:ok, body} <- fetch_map(map, "r"),
         {:ok, node_id} <- fetch_node_id(body["id"]) do
      response = %{
        transaction_id: tid,
        node_id: node_id,
        nodes: body["nodes"],
        values: body["values"],
        token: body["token"],
        version: map["v"]
      }

      {:ok, {:response, response}}
    else
      {:error, _} = error -> error
    end
  end

  defp decode_typed("e", map, tid) do
    with [code, message | _] <- map["e"],
         true <- is_integer(code) and is_binary(message) do
      {:ok,
       {:error,
        %{
          transaction_id: tid,
          code: code,
          message: message,
          version: map["v"]
        }}}
    else
      _ -> {:error, :malformed_error}
    end
  end

  defp decode_typed(_, _, _), do: {:error, :unknown_type}

  @spec query_args(query(), method()) :: map()
  defp query_args(%{target: target}, :find_node) when is_binary(target), do: %{"target" => target}

  defp query_args(%{info_hash: hash}, :get_peers) when byte_size(hash) == 20,
    do: %{"info_hash" => hash}

  defp query_args(%{info_hash: hash, port: port, token: token} = q, :announce_peer)
       when byte_size(hash) == 20 and is_integer(port) and is_binary(token) do
    args = %{"info_hash" => hash, "port" => port, "token" => token}

    case Map.get(q, :implied_port) do
      n when n in [0, 1] -> Map.put(args, "implied_port", n)
      _ -> args
    end
  end

  defp query_args(_, _), do: %{}

  @spec merge_query_args(query(), method(), map()) :: query()
  defp merge_query_args(query, :find_node, %{"target" => target}) when is_binary(target) do
    Map.put(query, :target, target)
  end

  defp merge_query_args(query, :get_peers, %{"info_hash" => hash}) when byte_size(hash) == 20 do
    Map.put(query, :info_hash, hash)
  end

  defp merge_query_args(query, :announce_peer, args) do
    query
    |> maybe_put(:info_hash, args["info_hash"])
    |> maybe_put(:port, args["port"])
    |> maybe_put(:token, args["token"])
    |> maybe_put(:implied_port, args["implied_port"])
  end

  defp merge_query_args(query, _, _), do: query

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec maybe_put_version(map(), map()) :: map()
  defp maybe_put_version(envelope, %{version: v}) when is_binary(v) and v != "",
    do: Map.put(envelope, "v", v)

  defp maybe_put_version(envelope, _), do: envelope

  @spec fetch_type(map()) :: {:ok, String.t()} | {:error, :malformed}
  defp fetch_type(%{"y" => <<type::binary-size(1)>>}), do: {:ok, type}
  defp fetch_type(_), do: {:error, :malformed}

  @spec fetch_method(term()) :: {:ok, method()} | {:error, :unknown_method}
  defp fetch_method("ping"), do: {:ok, :ping}
  defp fetch_method("find_node"), do: {:ok, :find_node}
  defp fetch_method("get_peers"), do: {:ok, :get_peers}
  defp fetch_method("announce_peer"), do: {:ok, :announce_peer}
  defp fetch_method(_), do: {:error, :unknown_method}

  @spec fetch_binary(map(), String.t()) :: {:ok, binary()} | {:error, :malformed}
  defp fetch_binary(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, :malformed}
    end
  end

  @spec fetch_map(map(), String.t()) :: {:ok, map()} | {:error, :malformed}
  defp fetch_map(map, key) do
    case Map.get(map, key) do
      v when is_map(v) -> {:ok, v}
      _ -> {:error, :malformed}
    end
  end

  @spec fetch_node_id(term()) :: {:ok, node_id()} | {:error, :malformed}
  defp fetch_node_id(id) when byte_size(id) == 20, do: {:ok, id}
  defp fetch_node_id(_), do: {:error, :malformed}

  @doc "Decode compact nodes from a get_peers / find_node response body."
  @spec response_nodes(response()) :: [Compact.contact()]
  def response_nodes(%{nodes: nodes}) when is_binary(nodes) do
    nodes |> Compact.decode_nodes() |> Enum.uniq_by(& &1.id)
  end

  def response_nodes(_), do: []

  @doc "Decode compact peers from a get_peers response body."
  @spec response_peers(response()) :: [Peer.t()]
  def response_peers(%{values: values}) when is_list(values) do
    values
    |> Enum.flat_map(fn
      peer when is_binary(peer) and byte_size(peer) == 6 ->
        Compact.decode_peers(peer)

      _ ->
        []
    end)
    |> Enum.uniq_by(&{&1.ip, &1.port})
  end

  def response_peers(_), do: []
end
