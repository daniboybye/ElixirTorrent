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
end
