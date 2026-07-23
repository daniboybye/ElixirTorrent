defmodule Peer.UtHolepunch do
  @moduledoc """
  BEP 55 `ut_holepunch` wire codec — binary payloads (not bencoded).

  IPv4 rendezvous/connect: 8 bytes. IPv6 connect: 20 bytes. IPv4 error: 12 bytes.
  """

  require Logger

  alias Peer.LTEP.Session

  @extension_name "ut_holepunch"

  @msg_rendezvous 0
  @msg_connect 1
  @msg_error 2

  @addr_ipv4 0
  @addr_ipv6 1

  # BEP 55 error codes carried in an :error message.
  @err_none 0
  @err_no_such_peer 1
  @err_not_connected 2
  @err_no_support 3
  @err_no_self 4

  @doc false
  def err_none, do: @err_none
  @doc false
  def err_no_such_peer, do: @err_no_such_peer
  @doc false
  def err_not_connected, do: @err_not_connected
  @doc false
  def err_no_support, do: @err_no_support
  @doc false
  def err_no_self, do: @err_no_self

  @doc false
  @spec err_name(non_neg_integer()) :: String.t()
  def err_name(@err_none), do: "none"
  def err_name(@err_no_such_peer), do: "no_such_peer"
  def err_name(@err_not_connected), do: "not_connected"
  def err_name(@err_no_support), do: "no_support"
  def err_name(@err_no_self), do: "no_self"
  def err_name(code), do: "unknown(#{code})"

  @type msg_type :: :rendezvous | :connect | :error
  @type decoded :: %{
          type: msg_type(),
          ip: :inet.ip_address(),
          port: :inet.port_number(),
          err_code: non_neg_integer() | nil
        }

  @doc false
  @spec extension_name() :: String.t()
  def extension_name, do: @extension_name

  @doc """
  Encodes a BEP 55 holepunch message.

  Options: `:err_code` (required for `:error`, default 0).
  """
  @spec encode(msg_type(), :inet.ip_address(), :inet.port_number(), keyword()) ::
          binary() | {:error, :unsupported_ip}
  def encode(type, ip, port, opts \\ []) do
    case type do
      :rendezvous -> encode_message(@msg_rendezvous, ip, port, nil)
      :connect -> encode_message(@msg_connect, ip, port, nil)
      :error -> encode_message(@msg_error, ip, port, Keyword.get(opts, :err_code, 0))
    end
  end

  @spec encode_message(byte(), :inet.ip_address(), :inet.port_number(), non_neg_integer() | nil) ::
          binary() | {:error, :unsupported_ip}
  defp encode_message(msg_type, {a, b, c, d}, port, err_code)
       when is_integer(port) and port in 1..65535 do
    base = <<msg_type, @addr_ipv4, a, b, c, d, port::16>>

    case err_code do
      nil -> base
      code when is_integer(code) -> base <> <<code::32>>
    end
  end

  defp encode_message(msg_type, {s1, s2, s3, s4, s5, s6, s7, s8}, port, err_code)
       when is_integer(port) and port in 1..65535 do
    base =
      <<msg_type, @addr_ipv6, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16,
        port::16>>

    case err_code do
      nil -> base
      code when is_integer(code) -> base <> <<code::32>>
    end
  end

  defp encode_message(_msg_type, _ip, _port, _err_code), do: {:error, :unsupported_ip}

  @doc """
  Decodes a BEP 55 holepunch payload.
  """
  @spec decode(binary()) :: {:ok, decoded()} | :error
  def decode(<<0, @addr_ipv4, a, b, c, d, port::16>>) do
    {:ok, %{type: :rendezvous, ip: {a, b, c, d}, port: port, err_code: nil}}
  end

  def decode(<<1, @addr_ipv4, a, b, c, d, port::16>>) do
    {:ok, %{type: :connect, ip: {a, b, c, d}, port: port, err_code: nil}}
  end

  def decode(<<2, @addr_ipv4, a, b, c, d, port::16, err_code::32>>) do
    {:ok, %{type: :error, ip: {a, b, c, d}, port: port, err_code: err_code}}
  end

  def decode(
        <<1, @addr_ipv6, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16,
          port::16>>
      ) do
    {:ok,
     %{
       type: :connect,
       ip: {s1, s2, s3, s4, s5, s6, s7, s8},
       port: port,
       err_code: nil
     }}
  end

  def decode(
        <<0, @addr_ipv6, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16,
          port::16>>
      ) do
    {:ok,
     %{
       type: :rendezvous,
       ip: {s1, s2, s3, s4, s5, s6, s7, s8},
       port: port,
       err_code: nil
     }}
  end

  def decode(
        <<2, @addr_ipv6, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, s8::16, port::16,
          err_code::32>>
      ) do
    {:ok,
     %{
       type: :error,
       ip: {s1, s2, s3, s4, s5, s6, s7, s8},
       port: port,
       err_code: err_code
     }}
  end

  def decode(_), do: :error

  @doc false
  @spec handle_inbound(Peer.Controller.State.t(), binary()) :: Peer.Controller.State.t()
  def handle_inbound(state, payload) when is_binary(payload) do
    case decode(payload) do
      {:ok, %{type: :rendezvous, ip: target_ip, port: target_port}} ->
        relay_rendezvous(state, target_ip, target_port)

      {:ok, %{type: :connect, ip: ip, port: port}} ->
        Logger.info(
          "[holepunch] connect_recv hash=#{Torrent.hex_encoded_hash(state.hash)} endpoint=#{inspect({ip, port})}"
        )

        :ok = Peer.Holepunch.initiate_connect(state.hash, {ip, port})
        state

      {:ok, %{type: :error, ip: ip, port: port, err_code: err_code}} ->
        # BEP 55: relay replies with an error (e.g. ENOTCONNECTED/target unknown)
        # when it can't reach the target. This is the normal outcome for most
        # rendezvous attempts, not a warning — just clear the pending attempt.
        Logger.debug(
          "[holepunch] error_recv hash=#{Torrent.hex_encoded_hash(state.hash)} endpoint=#{inspect({ip, port})} code=#{err_code}"
        )

        :ok = Peer.Holepunch.clear_pending(state.hash, ip, port)
        state

      :error ->
        state
    end
  end

  # BEP 55 relay role: an initiator we're connected to asks us to rendezvous
  # with `target`. If we can, we send a `connect` to BOTH the initiator and the
  # target so they open a uTP connection to each other simultaneously. If we
  # can't, we reply to the initiator with the specific error code so it stops
  # retrying instead of guessing from a silent drop.
  @spec relay_rendezvous(Peer.Controller.State.t(), :inet.ip_address(), :inet.port_number()) ::
          Peer.Controller.State.t()
  defp relay_rendezvous(state, target_ip, target_port) do
    hash = state.hash

    cond do
      self_target?(state, target_ip, target_port) ->
        relay_error(state, target_ip, target_port, @err_no_self)

      not Peer.Endpoints.registered?(hash, target_ip, target_port) ->
        relay_error(state, target_ip, target_port, @err_not_connected)

      true ->
        case target_session(hash, target_ip, target_port) do
          {:ok, target_key, target_ltep} ->
            if Session.peer_supports?(target_ltep, @extension_name) do
              do_relay(state, target_key, target_ltep, target_ip, target_port)
            else
              relay_error(state, target_ip, target_port, @err_no_support)
            end

          :error ->
            relay_error(state, target_ip, target_port, @err_no_such_peer)
        end
    end
  end

  @spec do_relay(
          Peer.Controller.State.t(),
          Peer.key(),
          Session.t(),
          :inet.ip_address(),
          :inet.port_number()
        ) :: Peer.Controller.State.t()
  defp do_relay(state, target_key, target_ltep, target_ip, target_port) do
    hash = state.hash
    initiator_key = Peer.Controller.State.key(state)

    with true <- Session.peer_supports?(state.ltep, @extension_name),
         {:ok, {init_ip, init_port}} <- peer_endpoint(state.socket),
         connect_to_initiator when is_binary(connect_to_initiator) <-
           encode_connect(init_ip, init_port),
         connect_to_target when is_binary(connect_to_target) <-
           encode_connect(target_ip, target_port) do
      # BEP 55 relay sends connect hints to two peers; either may drop mid-relay
      # (Endpoints still registered briefly while Sender/uTP is shutting down).
      case relay_connect_sends(
             hash,
             {target_ip, target_port},
             {init_ip, init_port},
             initiator_key,
             state.ltep,
             connect_to_initiator,
             target_key,
             target_ltep,
             connect_to_target
           ) do
        :ok ->
          Logger.info(
            "[holepunch] rendezvous_relay hash=#{Torrent.hex_encoded_hash(hash)} target=#{inspect({target_ip, target_port})} initiator=#{inspect({init_ip, init_port})}"
          )

          state

        {:error, reason} ->
          Logger.debug(
            "[holepunch] relay_send_failed hash=#{Torrent.hex_encoded_hash(hash)} target=#{inspect({target_ip, target_port})} reason=#{inspect(reason)}"
          )

          state
      end
    else
      _ -> state
    end
  end

  @spec relay_connect_sends(
          Torrent.hash(),
          {:inet.ip_address(), :inet.port_number()},
          {:inet.ip_address(), :inet.port_number()},
          Peer.key(),
          Session.t(),
          binary(),
          Peer.key(),
          Session.t(),
          binary()
        ) :: :ok | {:error, term()}
  defp relay_connect_sends(
         _hash,
         _target,
         _initiator,
         initiator_key,
         initiator_ltep,
         connect_to_initiator,
         target_key,
         target_ltep,
         connect_to_target
       ) do
    with :ok <- send_to_peer(initiator_key, initiator_ltep, connect_to_initiator),
         :ok <- send_to_peer(target_key, target_ltep, connect_to_target) do
      :ok
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  # Reply to the initiator with a BEP 55 error message naming why we couldn't relay.
  @spec relay_error(
          Peer.Controller.State.t(),
          :inet.ip_address(),
          :inet.port_number(),
          non_neg_integer()
        ) :: Peer.Controller.State.t()
  defp relay_error(state, target_ip, target_port, code) do
    initiator_key = Peer.Controller.State.key(state)

    case encode(:error, target_ip, target_port, err_code: code) do
      bin when is_binary(bin) ->
        case send_to_peer(initiator_key, state.ltep, bin) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end

      _ ->
        :ok
    end

    Logger.debug(
      "[holepunch] relay_error hash=#{Torrent.hex_encoded_hash(state.hash)} target=#{inspect({target_ip, target_port})} code=#{err_name(code)}"
    )

    state
  end

  # BEP 55 NoSelf guard: the initiator must not ask us to punch to itself.
  @spec self_target?(Peer.Controller.State.t(), :inet.ip_address(), :inet.port_number()) ::
          boolean()
  defp self_target?(state, ip, port) do
    case peer_endpoint(state.socket) do
      {:ok, {^ip, ^port}} -> true
      _ -> false
    end
  end

  @spec target_session(Torrent.hash(), :inet.ip_address(), :inet.port_number()) ::
          {:ok, Peer.key(), Session.t()} | :error
  defp target_session(hash, target_ip, target_port) do
    with target_key when not is_nil(target_key) <-
           peer_key_for_endpoint(hash, target_ip, target_port),
         {:ok, target_ltep} <- Peer.Controller.ltep_session(target_key) do
      {:ok, target_key, target_ltep}
    else
      _ -> :error
    end
  end

  @spec send_to_peer(Peer.key(), Session.t(), binary()) :: :ok | {:error, term()}
  defp send_to_peer(key, ltep, payload) do
    case Session.peer_extension_id(ltep, @extension_name) do
      id when is_integer(id) and id > 0 ->
        Peer.LTEP.send_extended(key, id, payload)

      _ ->
        :ok
    end
  end

  @spec peer_endpoint(Peer.Transport.socket()) ::
          {:ok, {:inet.ip_address(), :inet.port_number()}} | :error
  defp peer_endpoint(socket) do
    case Peer.Transport.safe_peername(socket) do
      {:ok, endpoint} -> {:ok, endpoint}
      _ -> :error
    end
  end

  @spec peer_key_for_endpoint(Torrent.hash(), :inet.ip_address(), :inet.port_number()) ::
          Peer.key() | nil
  defp peer_key_for_endpoint(hash, ip, port) do
    case Peer.Endpoints.get_pid(hash, ip, port) do
      pid when is_pid(pid) -> Peer.get_key(pid)
      _ -> nil
    end
  end

  @spec encode_connect(:inet.ip_address(), :inet.port_number()) :: binary() | nil
  defp encode_connect(ip, port) do
    case encode(:connect, ip, port) do
      bin when is_binary(bin) -> bin
      _ -> nil
    end
  end
end
