defmodule NAT.UPnPTest do
  use ExUnit.Case, async: true

  @nokia_snippet """
  <serviceList>
    <service>
      <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
      <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
      <controlURL>/upnp/control/WANIPConn1</controlURL>
    </service>
    <service>
      <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
      <serviceId>urn:upnp-org:serviceId:WANPPPConn1</serviceId>
      <controlURL>/upnp/control/WANPPPConn1</controlURL>
    </service>
  </serviceList>
  """

  test "parse_device_services prefers WANIPConnection:2 over WANPPPConnection:1" do
    location = "http://192.168.1.1:49153/gatedesc.xml"

    assert {:ok, {control_url, service_type}} =
             NAT.UPnP.parse_device_services(@nokia_snippet, location)

    assert service_type == "urn:schemas-upnp-org:service:WANIPConnection:2"
    assert control_url == "http://192.168.1.1:49153/upnp/control/WANIPConn1"
  end

  test "add_port_mapping_body uses the discovered service namespace" do
    service_type = "urn:schemas-upnp-org:service:WANIPConnection:2"
    body = NAT.UPnP.add_port_mapping_body("TCP", 6881, 6881, 7200, service_type)

    assert body =~ ~s|xmlns:u="#{service_type}"|
    assert body =~ "<NewExternalPort>6881</NewExternalPort>"
  end

  test "delete_port_mapping_body uses the discovered service namespace" do
    service_type = "urn:schemas-upnp-org:service:WANIPConnection:2"
    body = NAT.UPnP.delete_port_mapping_body("UDP", 6881, service_type)

    assert body =~ ~s|xmlns:u="#{service_type}"|
    assert body =~ "<NewExternalPort>6881</NewExternalPort>"
    assert body =~ "<NewProtocol>UDP</NewProtocol>"
  end

  test "get_external_ip_body uses the discovered service namespace" do
    service_type = "urn:schemas-upnp-org:service:WANIPConnection:2"
    body = NAT.UPnP.get_external_ip_body(service_type)

    assert body =~ ~s|xmlns:u="#{service_type}"|
    assert body =~ "GetExternalIPAddress"
  end

  test "parse_device_services falls back to WANPPPConnection:1" do
    body = """
    <service>
      <serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
      <controlURL>/upnp/control/WANPPPConn1</controlURL>
    </service>
    """

    assert {:ok, {url, type}} = NAT.UPnP.parse_device_services(body, "http://gw/igd.xml")
    assert type == "urn:schemas-upnp-org:service:WANPPPConnection:1"
    assert url == "http://gw/upnp/control/WANPPPConn1"
  end

  test "parse_device_services keeps absolute controlURL unchanged" do
    absolute = "http://192.168.1.1:49153/upnp/control/WANIPConn1"

    body = """
    <service>
      <serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType>
      <controlURL>#{absolute}</controlURL>
    </service>
    """

    location = "http://192.168.1.1:49153/gatedesc.xml"

    assert {:ok, {url, type}} = NAT.UPnP.parse_device_services(body, location)
    assert type == "urn:schemas-upnp-org:service:WANIPConnection:2"
    assert url == absolute
  end

  test "parse_device_services resolves relative controlURL without leading slash" do
    body = """
    <service>
      <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
      <controlURL>upnp/control/WANIPConn1</controlURL>
    </service>
    """

    location = "http://gw/sub/igd.xml"

    assert {:ok, {url, type}} = NAT.UPnP.parse_device_services(body, location)
    assert type == "urn:schemas-upnp-org:service:WANIPConnection:1"
    assert url == "http://gw/sub/upnp/control/WANIPConn1"
  end

  test "parse_device_services returns no_control_url when no WAN service is present" do
    body = """
    <service>
      <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
      <controlURL>/ctl/content</controlURL>
    </service>
    """

    assert {:error, :no_control_url} =
             NAT.UPnP.parse_device_services(body, "http://gw/igd.xml")
  end

  describe "loopback SOAP IGD control" do
    @service_type "urn:schemas-upnp-org:service:WANIPConnection:2"

    test "add_port_mapping succeeds and sends exact SOAPAction and body fields" do
      test_pid = self()

      {port, _pid} =
        start_soap_server(fn request ->
          send(test_pid, {:soap_request, :add, request})
          {200, soap_response("AddPortMappingResponse")}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert :ok =
               NAT.UPnP.add_port_mapping(control_url, @service_type, :tcp, 6881, 7200)

      assert_receive {:soap_request, :add, request}
      assert soap_action(request) == ~s|"#{@service_type}#AddPortMapping"|
      assert request =~ ~s|<u:AddPortMapping xmlns:u="#{@service_type}">|
      assert request =~ "<NewExternalPort>6881</NewExternalPort>"
      assert request =~ "<NewInternalPort>6881</NewInternalPort>"
      assert request =~ "<NewProtocol>TCP</NewProtocol>"
      assert request =~ "<NewLeaseDuration>7200</NewLeaseDuration>"
      assert request =~ "<NewPortMappingDescription>ElixirTorrent</NewPortMappingDescription>"
    end

    test "add_port_mapping returns upnp_rejected when 200 body lacks response marker" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {200, "<s:Envelope><s:Body><u:Fault/></s:Body></s:Envelope>"}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, :upnp_rejected} =
               NAT.UPnP.add_port_mapping(control_url, @service_type, :udp, 6881, 3600)
    end

    test "add_port_mapping returns upnp_http for non-200 status" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {500, "Internal Server Error"}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, {:upnp_http, 500}} =
               NAT.UPnP.add_port_mapping(control_url, @service_type, :tcp, 6881, 7200)
    end

    test "delete_port_mapping succeeds and sends exact SOAPAction and body fields" do
      test_pid = self()

      {port, _pid} =
        start_soap_server(fn request ->
          send(test_pid, {:soap_request, :delete, request})
          {200, soap_response("DeletePortMappingResponse")}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert :ok = NAT.UPnP.delete_port_mapping(control_url, @service_type, :udp, 6881)

      assert_receive {:soap_request, :delete, request}
      assert soap_action(request) == ~s|"#{@service_type}#DeletePortMapping"|
      assert request =~ ~s|<u:DeletePortMapping xmlns:u="#{@service_type}">|
      assert request =~ "<NewExternalPort>6881</NewExternalPort>"
      assert request =~ "<NewProtocol>UDP</NewProtocol>"
    end

    test "delete_port_mapping returns upnp_rejected when 200 body lacks response marker" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {200, "<html>rejected</html>"}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, :upnp_rejected} =
               NAT.UPnP.delete_port_mapping(control_url, @service_type, :tcp, 6881)
    end

    test "delete_port_mapping returns upnp_http for non-200 status" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {403, "Forbidden"}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, {:upnp_http, 403}} =
               NAT.UPnP.delete_port_mapping(control_url, @service_type, :tcp, 6881)
    end

    test "get_external_ip returns trimmed address from SOAP response" do
      test_pid = self()

      {port, _pid} =
        start_soap_server(fn request ->
          send(test_pid, {:soap_request, :get_ip, request})
          {200, external_ip_response("  203.0.113.42  ")}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:ok, "203.0.113.42"} =
               NAT.UPnP.get_external_ip(control_url, @service_type)

      assert_receive {:soap_request, :get_ip, request}
      assert soap_action(request) == ~s|"#{@service_type}#GetExternalIPAddress"|
      assert request =~ ~s|<u:GetExternalIPAddress xmlns:u="#{@service_type}">|
    end

    test "get_external_ip returns no_external_ip when tag is empty" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {200, external_ip_response("")}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, :no_external_ip} =
               NAT.UPnP.get_external_ip(control_url, @service_type)
    end

    test "get_external_ip returns no_external_ip when tag is missing" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {200, soap_response("GetExternalIPAddressResponse")}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, :no_external_ip} =
               NAT.UPnP.get_external_ip(control_url, @service_type)
    end

    test "get_external_ip returns upnp_http for non-200 status" do
      {port, _pid} =
        start_soap_server(fn _request ->
          {502, "Bad Gateway"}
        end)

      control_url = "http://127.0.0.1:#{port}/ctl"

      assert {:error, {:upnp_http, 502}} =
               NAT.UPnP.get_external_ip(control_url, @service_type)
    end
  end

  defp start_soap_server(responder) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        serve_soap(listen, responder)
      end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end)

    {port, pid}
  end

  defp serve_soap(listen, responder) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> handle_soap_client(socket, responder) end)
        serve_soap(listen, responder)

      {:error, _} ->
        :ok
    end
  end

  defp handle_soap_client(socket, responder) do
    case recv_http_request(socket, <<>>) do
      {:ok, request} ->
        {code, body} =
          case responder.(request) do
            {c, b} -> {c, b}
            {c, b, _headers} -> {c, b}
          end

        status = if code == 200, do: "200 OK", else: "#{code} Error"

        response =
          [
            "HTTP/1.1 #{status}\r\n",
            "Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n",
            body
          ]
          |> IO.iodata_to_binary()

        :gen_tcp.send(socket, response)

      {:error, _} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp recv_http_request(socket, buffer) do
    case complete_http_request(buffer) do
      {:ok, request} ->
        {:ok, request}

      :incomplete ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> recv_http_request(socket, buffer <> chunk)
          {:error, _} = error -> error
        end
    end
  end

  defp complete_http_request(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_end, 4} ->
        body_start = header_end + 4
        headers = binary_part(buffer, 0, header_end)

        content_length =
          case Regex.run(~r/^Content-Length:\s*(\d+)\s*$/im, headers) do
            [_, value] -> String.to_integer(value)
            _ -> 0
          end

        if byte_size(buffer) >= body_start + content_length,
          do: {:ok, binary_part(buffer, 0, body_start + content_length)},
          else: :incomplete

      :nomatch ->
        :incomplete
    end
  end

  defp soap_action(request) when is_binary(request) do
    case Regex.run(~r/^SOAPAction:\s*(.+)\s*$/im, request) do
      [_, action] -> String.trim(action)
      _ -> nil
    end
  end

  defp soap_response(action) do
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <u:#{action} xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:2"/>
      </s:Body>
    </s:Envelope>
    """
  end

  defp external_ip_response(ip) do
    """
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
      <s:Body>
        <u:GetExternalIPAddressResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:2">
          <NewExternalIPAddress>#{ip}</NewExternalIPAddress>
        </u:GetExternalIPAddressResponse>
      </s:Body>
    </s:Envelope>
    """
  end
end
