# The web server

[Back to the README](../README.md).


**Bind apps to loopback.** Each app runs under systemd as its own system user, listening on `127.0.0.1` only. Code and venv under `/srv/<app>/` are root-owned and read-only; `ProtectSystem=strict` with one `ReadWritePaths=` for data.

**Publish through an outbound tunnel.** This setup uses Cloudflare Tunnel (`cloudflared` as a service) behind Cloudflare Access: TLS ends at Cloudflare's edge and no inbound port is open. Route by hostname, ending in a catch-all:

```yaml
ingress:
  - hostname: app.example.com
    service: http://127.0.0.1:8000   # the literal address: localhost may resolve to ::1 first
  - service: http_status:404
```

Run `cloudflared tunnel ingress validate`, then `systemctl restart cloudflared` (`reload` fails: no `ExecReload=`). Verify by fetching every hostname from outside your network.

- Cloudflare rolled over its package signing key on 30 October 2025. A machine that still holds the old key stops getting updates: RPM systems and Debian Trixie at once, others once the old key was removed on 30 April 2026. Download `cloudflare-main.gpg` again to fix it (the pkg.cloudflare.com notice, read from its source on 2026-10-17).
- Check which login methods your Access organization has. Here one-time PIN was off, so only the account owner could sign in, and the owner could not tell. Organizations created since 2026-06-18 start with the Cloudflare identity provider, which admits only members of your Cloudflare account ([changelog](https://developers.cloudflare.com/changelog/post/2026-06-18-cloudflare-idp-default/)). Test from an address with no Cloudflare account.
- Removing someone from the policy does not end their session. Revoke their tokens too.

Have each app verify the signed `Cf-Access-Jwt-Assertion` against the application's audience, refuse everything if the audience is unset, and ignore the email header.

**Firewall.** ufw: deny incoming, allow outgoing; allow 22/tcp from the LAN, anything on `tailscale0`, and 41641/udp so Tailscale connects directly. Check `IPV6=yes` in `/etc/default/ufw` (the Ubuntu 24.04 default): before ufw, port 22 was open on this host's public IPv6 address.

**Deploy by push.** The web server holds no key, so it cannot pull. Every deploy script here has this shape:

```bash
#!/usr/bin/env bash
set -euo pipefail
HOST="${1:-web-server}"
ssh "$HOST" 'rm -rf ~/app-stage && mkdir -p ~/app-stage'
rsync -a --delete --exclude '__pycache__' --exclude '*.pyc' app/ "$HOST:app-stage/app/"
rsync -a requirements.txt deploy/app.service deploy/app.env.example "$HOST:app-stage/"
ssh "$HOST" 'bash -euo pipefail -s' <<'REMOTE'
S=~/app-stage
id app >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin app
sudo install -d -m 0755 /srv/app
sudo rsync -a --delete "$S/app/" /srv/app/app/
sudo chown -R root:root /srv/app/app && sudo chmod -R go-w /srv/app/app
[ -x /srv/app/.venv/bin/python ] || sudo python3 -m venv /srv/app/.venv
sudo /srv/app/.venv/bin/pip install -q -r "$S/requirements.txt"
sudo install -d -o root -g app -m 0750 /etc/app
sudo test -f /etc/app/app.env || sudo install -o root -g app -m 0640 "$S/app.env.example" /etc/app/app.env
sudo install -m 0644 "$S/app.service" /etc/systemd/system/app.service
sudo systemctl daemon-reload && sudo systemctl enable --now app && sudo systemctl restart app
rm -rf "$S"
REMOTE
ssh "$HOST" 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/'  # want 403
curl -s -o /dev/null -w '%{http_code}\n' https://app.example.com/             # want 302
```

Copy code, never the local venv: its shebangs point at paths absent on the target. Write the env file only if missing, tested with `sudo test`: a plain `[ -f ]` cannot see into the `0750` directory and overwrites your config every run. The real scripts also run the app's selftest on the server. A 403 on loopback is correct, since the request carries no Access token; a 200 means verification is off.

- A backgrounded process over SSH holds the session open. Use `systemd-run --unit=<name>`.

## The deploy account

The account the agents log in as is locked (no password, not in `sudo`), and its sudoers file lists each command of the deploy script above, exactly, as a `Cmnd_Alias` with regular expressions where a path varies (`/srv/(app|other)/`), plus a read-only alias for `systemctl status`, `journalctl`, `ss` and `ufw status`, an upgrade alias for the two `apt-get` forms the upgrade script uses, and the selftests as the service users (`claude ALL=(app) NOPASSWD: ...`). It replaced `NOPASSWD: ALL` here on 2026-10-23 and the deploys run through it. Two things to know: the deploy alias still reaches root in one step by design (`pip install` as root runs package builds, and the unit file it installs says what runs), so it narrows accidents, not a hostile agent; and the capture script's `sudo -n cat` list is an alias of its own, naming every file it may read and none of the credentials. Keep the sudoers source in the repository beside the deploy script it mirrors, and reinstall both together. The read-only alias here was written with the same `systemctl`, `journalctl` and `ss` forms as the agent server's, and had the same gaps ([the agent as its own user](agent-account.md#the-sudo-allowlist)); it carries the corrected forms since 2026-10-26, installed and probed the same way.

**Capture its config.** A second script pulls the server's hand-made files over SSH with `sudo -n cat` (sshd drop-in, netplan, ufw rules, fstab, tunnel config, units), excluding the tunnel credentials, account certificate, app env files and host keys; it takes those files' modification times, so a check can tell when a secret changed after the owner's last archive of them. Run it after any change under the server's `/etc`, and commit. Anything root runs on a timer is a root-owned copy under `/usr/local/sbin`, never a file in a user's home ([the agent as its own user](agent-account.md#root-runs-no-agent-owned-file-unattended)).

**The stop rule.** Put it in your agents' rules: stop and ask before touching credentials, Tailscale or sshd anywhere, or the web server's firewall and tunnel config. Those are the paths in, and nobody is at the machine to recover them. Access applications, tunnel routes and DNS stay a human job in the dashboard.
