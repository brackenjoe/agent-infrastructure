# Network and access

[Back to the README](../README.md).


Put every machine on one Tailscale network. Join each server with a tagged auth key; tagged devices have key expiry off by default (Tailscale, Auth keys, read 2026-10-17). This tailnet uses grants:

```json
{
  "tagOwners": {
    "tag:agents": [], "tag:webserver": [], "tag:tak": [], "tag:sensor": []
  },
  "grants": [
    {"src": ["autogroup:member"], "dst": ["tag:agents", "tag:webserver"], "ip": ["tcp:22"]},
    {"src": ["autogroup:member"], "dst": ["tag:tak"], "ip": ["tcp:8089", "tcp:8443"]},
    {"src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"]},
    {"src": ["tag:agents"], "dst": ["tag:webserver", "tag:sensor"], "ip": ["tcp:22"]},
    {"src": ["tag:webserver"], "dst": ["tag:tak"], "ip": ["tcp:8089", "tcp:8443"]}
  ],
  "ssh": [
    {"action": "check", "src": ["autogroup:member"], "dst": ["tag:agents"], "users": ["you", "agent"]}
  ],
  "tests": [
    {"src": "tag:tak", "proto": "tcp", "deny": ["tag:agents:22", "tag:webserver:22", "tag:sensor:22"]},
    {"src": "tag:agents", "proto": "tcp", "accept": ["tag:webserver:22", "tag:sensor:22"], "deny": ["tag:tak:22", "tag:tak:8443"]}
  ],
  "sshTests": [
    {"src": "tag:tak", "dst": ["tag:agents"], "deny": ["you", "agent", "root"]}
  ]
}
```

List the ports your own devices use; the first version of this policy
gave them every port on every machine. `tests` and `sshTests` make the
console refuse a save that breaks one of them, and name the failing test.

Nothing grants `tag:agents` a path to `tag:tak`, and a test says so; check the TAK server from your own device. The `ssh` block lets your phone or laptop use Tailscale SSH into the agent server (`tailscale set --ssh` on it), as the accounts it names, after you sign in again with your identity provider, every 12 hours by default (`check`; Tailscale, Tailscale SSH, read 2026-11-05): `you` and `agent` stand for your login and the agent's ([the agent as its own user](agent-account.md)). `autogroup:nonroot` would let any account but root log in; name the accounts you mean instead (Tailscale, Tailscale SSH and policy file reference, read 2026-10-17). Whether that list includes the agent's account decides how you reach its terminals.

**Tag every server, including one you signed in yourself.** A device signed in with your own login is not tagged: it is `autogroup:member` and `autogroup:self`, so a rule meant for your phone and laptop covers it too. Here the TAK server had been signed in that way, and reached the agent server, the web server and every personal device on every port, and could use the SSH rule, until it was tagged `tag:tak` (2026-11-01). After tagging, probe from each server: a port that times out was dropped by the policy, and one that is refused reached the host.

- A tagged node is not `autogroup:member`. A rule with that source never matches your servers (Tailscale, Kubernetes operator Funnel page, read 2026-10-17).
- An `ssh` block is not network access, and does nothing unless the target runs Tailscale SSH. The web server here does not; it uses system sshd over the tcp:22 grant.
- Taildrop refuses tagged nodes (Tailscale, Taildrop, read 2026-10-17). Pull files over SFTP (Termius on the phone, here).

**SSH.** On each target, create `deploy` with `adduser --disabled-password`, holding one key made for that target alone. Its sudo is an allowlist of the deploy's exact commands, not `NOPASSWD: ALL` ([the web server](web-server.md#the-deploy-account)). Revoke by deleting its line from `~deploy/.ssh/authorized_keys`. On the agent server:

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
