-- UPnP helper parsing (src/net/upnp.lua). The network path itself needs a
-- real router and is exercised by hand.
local U = require("src.net.upnp")
local discord = require("src.platform.discord")

return function(t)
  t.describe("upnp", function()
    t.it("parses LOCATION case-insensitively", function()
      local r = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nlocation: http://192.168.1.1:5000/rootDesc.xml\r\nST: upnp:rootdevice\r\n\r\n"
      t.eq(U.parseLocation(r), "http://192.168.1.1:5000/rootDesc.xml")
      t.isNil(U.parseLocation("HTTP/1.1 200 OK\r\nST: x\r\n\r\n"))
    end)

    t.it("resolves relative control URLs", function()
      local base = "http://192.168.1.1:5000/desc/root.xml"
      t.eq(U.resolveUrl(base, "/ctl/IPConn"), "http://192.168.1.1:5000/ctl/IPConn")
      t.eq(U.resolveUrl(base, "ctl/IPConn"), "http://192.168.1.1:5000/desc/ctl/IPConn")
      t.eq(U.resolveUrl(base, "http://10.0.0.1/x"), "http://10.0.0.1/x")
      local root, host, path = U.splitUrl("http://192.168.1.1:5000")
      t.eq({ root, host, path }, { "http://192.168.1.1:5000", "192.168.1.1", "/" })
    end)

    t.it("scopes controlURL to the WAN connection service block", function()
      local xml = [[<root><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
          <controlURL>/ctl/CmnIfCfg</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType>
          <controlURL>/ctl/PPPConn</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
          <controlURL> /ctl/IPConn </controlURL></service>
      </serviceList></device></root>]]
      local url, st = U.findControlUrl(xml, "http://192.168.1.1:5000/rootDesc.xml")
      t.eq(url, "http://192.168.1.1:5000/ctl/IPConn")
      t.eq(st, "urn:schemas-upnp-org:service:WANIPConnection:1")
      t.isNil(U.findControlUrl("<root><service><serviceType>x</serviceType><controlURL>/a</controlURL></service></root>", "http://h/"))
    end)

    t.it("builds the AddPortMapping envelope", function()
      local body = U.soapEnvelope("urn:x:1", "AddPortMapping", U.addFields(4040, "192.168.1.20", "Cardtable"))
      t.ok(body:find('<u:AddPortMapping xmlns:u="urn:x:1">', 1, true))
      t.ok(body:find("<NewInternalClient>192.168.1.20</NewInternalClient>", 1, true))
      t.ok(body:find("<NewExternalPort>4040</NewExternalPort>", 1, true))
    end)
  end)

  t.describe("discord", function()
    t.it("parses host:port join secrets", function()
      local h, p = discord.parseJoinSecret("203.0.113.7:4040")
      t.eq({ h, p }, { "203.0.113.7", 4040 })
      t.isNil(discord.parseJoinSecret("nope"))
      t.isNil(discord.parseJoinSecret(":4040"))
    end)

    t.it("is a no-op before init", function()
      discord.setIdle()
      discord.update(1)
      t.eq(discord.fetchInvitableFriends(), {})
      local got
      discord.ensureAuthorizedAndConnected(function(ok) got = ok end)
      t.eq(got, false)
    end)
  end)
end
