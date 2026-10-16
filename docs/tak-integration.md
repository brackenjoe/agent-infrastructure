# TAK Server integration

[Back to the README](../README.md). The niche part of this setup: skip it unless you run TAK.


The web app uploads a finished mission plan to a TAK Server as a data
package, then sends one Cursor on Target (CoT) message prompting connected
devices to fetch it. Agents write the code and the server steps; a person
runs the steps and checks the devices.

### Pin the version, then check every claim against it

This setup runs **TAK Server 5.8-RELEASE84** (all-in-one Ubuntu package,
PostgreSQL 18). It was built against 5.7-RELEASE43 and re-verified with a
real send after the upgrade, code unchanged.

Read the running version from the messaging log, not from systemd. After a
failed install, `systemctl is-active` reported a healthy service that was
still the old version:

```
sudo grep VersionBean /opt/tak/logs/takserver-messaging.log | tail -2
```

Do not let an agent answer version-dependent TAK behaviour from memory.
The API docs sit behind the tak.gov login; the public GitHub mirror stops
at 5.7-RELEASE-14. Here the upload endpoint and the
file-share CoT format were read from ATAK-CIV's client source
(`commoncommo`, archived 2025-05-02), then confirmed against the real
server. Make the agent name its source and version beside each claim.

### No agent has a path to the TAK server

The agent server has no network path to `tak-server`. The web server reaches
it on 8443 (HTTPS, Marti API) and 8089 (TLS CoT streaming) only, with no
SSH. Agents deploy to the web server with sudo and it holds the TAK client
certificate, so the rule that keeps an agent from sending through it is the
stop rule, not the network. [Network and access](network.md) has the grants.

So for each server change the agent writes the exact commands and the
exact output to send back; you run them and paste the output in, one round
trip per step. Back up before any change
(database dump plus all of `/opt/tak`). That backup holds the CA and every
client key, so keep it off the repo and off the agent server.

Treat certificates, device enrollment and server passwords as credentials:
configure your agents to stop and ask every time.

### The web server's identity

The web server presents a client certificate, issued by the TAK Server's
own CA. You run this on `tak-server`:

```
cd /opt/tak/certs
sudo ./makeCert.sh client webserver-client
# copy files/webserver-client.pem, files/webserver-client.key and
# files/ca.pem to web-server by hand (never in the deploy), mode 0640
# if the key is passphrase-protected, strip it with: openssl rsa
```

`ca.pem` must be the CA that signed the server certificate, whose name
must match the hostname the app connects to.

No admin role or group was assigned to it, so it shares the devices'
default group (`__ANON__`): an unaddressed announce reached every
connected device. Access is controlled in the app
instead, by an operator allowlist that is empty by default. Restricting the
certificate to a named group is not tested here.

### What the web app sends

1. **Upload.** The plan is wrapped in a zip with `MANIFEST/manifest.xml`
   and POSTed to `https://tak-server:8443/Marti/sync/missionupload` with
   `hash`, `filename` and `creatorUid` query parameters, multipart field
   `assetfile`. HTTP 200 means it landed.
2. **Announce.** One CoT event, type `b-f-t-r`, `how="h-e"`, with a
   `<fileshare>` detail (`filename`, `senderUrl`, `sizeInBytes`, `sha256`,
   `senderUid`, `senderCallsign`, `name`, `peerHosted="false"`), sent over
   TLS to `tak-server:8089`.

```python
import socket, ssl
import requests

# sha256, uid, zip_bytes: the package and its id; cot_xml: the announce event
r = requests.post(
    "https://tak-server:8443/Marti/sync/missionupload",
    params={"hash": sha256, "filename": "plan.zip", "creatorUid": uid},
    files={"assetfile": ("plan.zip", zip_bytes, "application/x-zip-compressed")},
    cert=("webserver-client.pem", "webserver-client.key"),
    verify="ca.pem", timeout=(5, 5), allow_redirects=False)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.load_verify_locations("ca.pem")
ctx.load_cert_chain("webserver-client.pem", "webserver-client.key")
sock = socket.create_connection(("tak-server", 8089), timeout=5)
with ctx.wrap_socket(sock, server_hostname="tak-server") as s:
    s.settimeout(5)
    s.sendall(cot_xml.encode())
```

State the uid and stale policy. Here the uid hashes operator and mission
name, so a re-send replaces the earlier plan, and the zip is byte-stable.
Stale is the mission window's end plus one hour, floored at now plus one
hour.

The manifest's `contentType` decides which ATAK importer runs. Coverage
rasters (KML `GroundOverlay`) did not show on the device until each was
split into its own KMZ marked `External GRG Data`, with the vectors left as
`KML`.

### Fail closed

Every failure ends in a recorded state (`sent`, `partial`, `unreachable`,
`refused`, `misconfigured`). Nothing is sent in the clear and nothing is
retried:

- A URL that is not `https://`, a bad `host:port`, a missing file, or a
  cert and key that do not load as a pair is `misconfigured`, caught before
  anything is built.
- TLS is always verified against the TAK CA, with hostname checking on.
- **Redirects are not followed.** A followed 3xx would resend the client
  certificate and the package to whatever host the reply names. A 3xx is
  `refused`.
- The download URL in the server's reply is used only if it is `https://`
  on the same host. Otherwise the app builds `/Marti/sync/content?hash=`,
  the URL a device builds anyway.
- The CoT timeout covers the TLS handshake too. A blocked tailnet host
  accepts TCP and then stalls.

A second-model review found six of these holes, three of them checks
that looked sufficient (file exists, string non-empty). Known and not
fixed: the upload timeout does not bound a stalled write.

### Test without a real server

The test suite starts a fake TAK server on localhost: a self-signed HTTPS
listener for the upload and a raw TLS listener for CoT. It parses what
arrives and asserts the manifest, the event type and `<fileshare>` detail,
the hash and uid reuse, that a 302 is refused after one call, and that a
wrong-hostname certificate is rejected with nothing received. The fake does not require a client certificate, so mutual TLS is
proven only against the real server. Checking against a CoT XSD is not
done here yet, although `tak-sme`'s rules require it: the events are checked
element by element, and the schema check is an open item.

Against the real server, send made-up data only: a fictional plan named
`TEST`, never a real flight.

### Confirm rendering on the device

A 200 proves the file landed, not that anything showed: here the server
accepted packages whose coverage never appeared on the phone. A person
looks at the device and reports. Two things learned that way:

- `marti` addressing routes on ATAK **callsigns**, not server usernames.
  Addressed to usernames, the announce reached nobody.
- A device offline at send time does not get the package when it comes
  back. Send again.
