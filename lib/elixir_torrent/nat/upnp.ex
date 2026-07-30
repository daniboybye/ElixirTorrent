defmodule NAT.UPnP do
  @moduledoc false

  require Logger

  @ssdp_address {239, 255, 255, 250}
  @ssdp_port 1900
  @search_timeout 2_000

  @service_block_pattern ~r/<serviceType>(urn:schemas-upnp-org:service:WAN(?:IP|PPP)Connection:\d+)<\/serviceType>.*?<controlURL>([^<]+)<\/controlURL>/s

  @service_preference [
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:1"
  ]

  @doc false
  @spec parse_device_services(String.t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def parse_device_services(body, location) when is_binary(body) and is_binary(location) do
    parse_control_url(body, location)
  end

  @spec discover_control_url() :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def discover_control_url do
    msearch =
      "M-SEARCH * HTTP/1.1\r\n" <>
        "HOST: 239.255.255.250:1900\r\n" <>
        "MAN: \"ssdp:discover\"\r\n" <>
        "MX: 1\r\n" <>
        "ST: urn:schemas-upnp-org:service:WANIPConnection:1\r\n" <>
        "\r\n"

    with {:ok, socket} <- open_multicast_socket(),
         :ok <- :gen_udp.send(socket, @ssdp_address, @ssdp_port, msearch),
         {:ok, response} <- recv_ssdp(socket, @search_timeout),
         :ok <- safe_close(socket),
         {:ok, location} <- parse_location(response),
         {:ok, {control_url, service_type}} <- fetch_control_url(location) do
      Logger.debug("[nat] upnp service=#{service_type} control_url=#{control_url}")
      {:ok, {control_url, service_type}}
    else
      {:error, _} = error -> error
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  @spec add_port_mapping(String.t(), String.t(), :tcp | :udp, :inet.port_number(), pos_integer()) ::
          :ok | {:error, term()}
  def add_port_mapping(control_url, service_type, proto, port, lifetime_seconds)
      when proto in [:tcp, :udp] and is_integer(port) and port > 0 and is_binary(service_type) do
    proto_str = if proto == :tcp, do: "TCP", else: "UDP"
    body = add_port_mapping_body(proto_str, port, port, lifetime_seconds, service_type)

    case HTTPoison.post(control_url, body, soap_headers(service_type, "AddPortMapping"),
           recv_timeout: 4_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp}} ->
        if String.contains?(resp, "AddPortMappingResponse") do
          :ok
        else
          {:error, :upnp_rejected}
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, {:upnp_http, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_port_mapping(String.t(), String.t(), :tcp | :udp, :inet.port_number()) ::
          :ok | {:error, term()}
  def delete_port_mapping(control_url, service_type, proto, port)
      when proto in [:tcp, :udp] and is_integer(port) and port > 0 and is_binary(service_type) do
    proto_str = if proto == :tcp, do: "TCP", else: "UDP"
    body = delete_port_mapping_body(proto_str, port, service_type)

    case HTTPoison.post(control_url, body, soap_headers(service_type, "DeletePortMapping"),
           recv_timeout: 4_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp}} ->
        if String.contains?(resp, "DeletePortMappingResponse") do
          :ok
        else
          {:error, :upnp_rejected}
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, {:upnp_http, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_external_ip(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def get_external_ip(control_url, service_type)
      when is_binary(control_url) and is_binary(service_type) do
    body = get_external_ip_body(service_type)

    case HTTPoison.post(control_url, body, soap_headers(service_type, "GetExternalIPAddress"),
           recv_timeout: 4_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: resp}} ->
        case Regex.run(~r/<NewExternalIPAddress>([^<]+)<\/NewExternalIPAddress>/, resp) do
          [_, ip] when ip != "" -> {:ok, String.trim(ip)}
          _ -> {:error, :no_external_ip}
        end

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, {:upnp_http, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec delete_port_mapping_body(String.t(), pos_integer(), String.t()) :: String.t()
  def delete_port_mapping_body(proto, external_port, service_type) do
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      <s:Body>
        <u:DeletePortMapping xmlns:u="#{service_type}">
          <NewRemoteHost></NewRemoteHost>
          <NewExternalPort>#{external_port}</NewExternalPort>
          <NewProtocol>#{proto}</NewProtocol>
        </u:DeletePortMapping>
      </s:Body>
    </s:Envelope>
    """
  end

  @doc false
  @spec get_external_ip_body(String.t()) :: String.t()
  def get_external_ip_body(service_type) do
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      <s:Body>
        <u:GetExternalIPAddress xmlns:u="#{service_type}">
        </u:GetExternalIPAddress>
      </s:Body>
    </s:Envelope>
    """
  end

  @doc false
  @spec add_port_mapping_body(String.t(), pos_integer(), pos_integer(), pos_integer(), String.t()) ::
          String.t()
  def add_port_mapping_body(proto, external_port, internal_port, lease, service_type) do
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
      <s:Body>
        <u:AddPortMapping xmlns:u="#{service_type}">
          <NewRemoteHost></NewRemoteHost>
          <NewExternalPort>#{external_port}</NewExternalPort>
          <NewProtocol>#{proto}</NewProtocol>
          <NewInternalPort>#{internal_port}</NewInternalPort>
          <NewInternalClient>#{internal_client()}</NewInternalClient>
          <NewEnabled>1</NewEnabled>
          <NewPortMappingDescription>ElixirTorrent</NewPortMappingDescription>
          <NewLeaseDuration>#{lease}</NewLeaseDuration>
        </u:AddPortMapping>
      </s:Body>
    </s:Envelope>
    """
  end

  defp internal_client do
    case Acceptor.ip() do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> "127.0.0.1"
    end
  end

  defp soap_headers(service_type, action) do
    [
      {"Content-Type", "text/xml; charset=\"utf-8\""},
      {"SOAPAction", "\"#{service_type}##{action}\""},
      {"User-Agent", "ElixirTorrent/1.0 UPnP/1.0"}
    ]
  end

  defp open_multicast_socket do
    case Acceptor.primary_ips().inet do
      nil ->
        {:error, :no_interface}

      local_ip ->
        opts = [
          :binary,
          active: false,
          reuseaddr: true,
          ip: local_ip,
          multicast_if: local_ip,
          add_membership: {@ssdp_address, local_ip}
        ]

        case :gen_udp.open(0, opts) do
          {:ok, socket} -> {:ok, socket}
          error -> error
        end
    end
  end

  defp recv_ssdp(socket, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    recv_ssdp_loop(socket, deadline)
  end

  defp recv_ssdp_loop(socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case :gen_udp.recv(socket, 0, remaining) do
        {:ok, {_ip, _port, data}} when is_binary(data) ->
          {:ok, data}

        {:ok, {_ip, _port, _ancillary_data, data}} when is_binary(data) ->
          {:ok, data}

        {:error, _} ->
          recv_ssdp_loop(socket, deadline)
      end
    end
  end

  defp parse_location(response) when is_binary(response) do
    case Regex.run(~r/^LOCATION:\s*(.+)\s*$/im, response) do
      [_, location] -> {:ok, String.trim(location)}
      _ -> {:error, :no_location}
    end
  end

  defp parse_location(_), do: {:error, :invalid_response}

  defp fetch_control_url(location) do
    case HTTPoison.get(location, [], recv_timeout: 4_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parse_control_url(body, location)

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, {:upnp_desc, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_control_url(body, location) do
    base = location |> URI.parse() |> Map.get(:path, "/") |> Path.dirname()

    services =
      @service_block_pattern
      |> Regex.scan(body)
      |> Map.new(fn [_full, service_type, control_path] -> {service_type, control_path} end)

    case preferred_wan_service(services) do
      {service_type, control_path} ->
        {:ok, {absolute_url(location, base, control_path), service_type}}

      nil ->
        {:error, :no_control_url}
    end
  end

  defp preferred_wan_service(services) when is_map(services) do
    Enum.find_value(@service_preference, fn service_type ->
      case Map.get(services, service_type) do
        nil -> nil
        control_path -> {service_type, control_path}
      end
    end)
  end

  defp absolute_url(location, base, path) do
    uri = URI.parse(location)

    path =
      cond do
        String.starts_with?(path, "http") -> path
        String.starts_with?(path, "/") -> path
        true -> Path.join(base, path)
      end

    if String.starts_with?(path, "http") do
      path
    else
      %URI{uri | path: path} |> URI.to_string()
    end
  end

  defp safe_close(socket) do
    :gen_udp.close(socket)
    :ok
  catch
    _, _ -> :ok
  end
end
