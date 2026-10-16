# Network and access

[Back to the README](../README.md).


Put every machine on one Tailscale network. Join each server with a tagged auth key; tagged devices have key expiry off by default. This tailnet uses grants:

```json
{
  "tagOwners": {
    "tag:agents": [], "tag:webserver": [], "tag:tak": [], "tag:sensor": []
  },
  "grants": [
    {"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},
    {"src": ["tag:agents"], "dst": ["tag:webserver", "tag:sensor"], "ip": ["tcp:22"]},
    {"src": ["tag:webserver"], "dst": ["tag:tak"], "ip": ["tcp:8089", "tcp:8443"]}
  ],
  "ssh": [
    {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:agents"], "users": ["autogroup:nonroot"]}
  ]
}
```

Nothing grants `tag:agents` a path to `tag:tak`; check the TAK server from your own device. The `ssh` block lets your phone or laptop use Tailscale SSH into the agent server (`tailscale up --ssh`); its `users` value is from Tailscale's docs, not tested here.

- A tagged node is not `autogroup:member`. A rule with that source never matches your servers.
- An `ssh` block is not network access, and does nothing unless the target runs Tailscale SSH. The web server here does not; it uses system sshd over the tcp:22 grant.
- Taildrop refuses tagged nodes. Pull files over SFTP (Termius on the phone, here).

**SSH.** On each target, create `deploy` with `adduser --disabled-password`, holding one key made for that target alone. Here it has passwordless sudo, because deploys install root-owned code and units; a narrower sudoers file is not tested here. Revoke by deleting its line from `~deploy/.ssh/authorized_keys`. On the agent server:

```
Host web-server
    HostName <web-server LAN address>
    User deploy
    IdentityFile ~/.ssh/id_ed25519_web-server

Host web-server-ts
    HostName <web-server tailnet name>
    User deploy
    IdentityFile ~/.ssh/id_ed25519_web-server
```

Do the same for `sensor-node`. Trust runs one way: targets hold no key back, so a compromised public machine cannot reach your agent server.
