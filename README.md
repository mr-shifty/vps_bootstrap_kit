# Base server bootstrap (Ubuntu/Debian)

Automates initial setup of a new server:
- creates admin user and adds to sudo
- sets SSH hardening options
- configures UFW firewall with mandatory ports and SSH restrictions
- enables fail2ban
- optionally issues SSL certificate via acme.sh (Let's Encrypt by default)
- enables unattended security updates
- sets timezone and optional hostname
- optionally creates swap file

## Files
- `bootstrap-server.sh` - main script
- `server-setup.env.example` - config template

## Quick start

1. Copy files to server:

```bash
scp bootstrap-server.sh server-setup.env.example root@<server_ip>:/root/
```

2. Connect to server:

```bash
ssh root@<server_ip>
```

3. Prepare config:

```bash
cd /root
cp server-setup.env.example server-setup.env
nano server-setup.env
```

4. Run bootstrap:

```bash
chmod +x bootstrap-server.sh
sudo ./bootstrap-server.sh ./server-setup.env
```

5. Open new SSH session and verify access:

```bash
ssh -p <SSH_PORT_FROM_ENV> <ADMIN_USER>@<server_ip>
```

## Notes
- Script targets Ubuntu/Debian family (uses `apt`).
- To avoid lockout, script keeps `PasswordAuthentication yes` if `ADMIN_PUBLIC_KEY` is empty.
- UFW setup performs `ufw reset`, which is expected on a fresh server.
- Available selectable TCP ports: `14228 80 443 8443 1234`.
- Opened ports are taken from `OPEN_TCP_PORTS` (subset of `AVAILABLE_TCP_PORTS`).
- If `OPEN_TCP_PORTS` contains a port outside `AVAILABLE_TCP_PORTS`, script stops with an error.
- SSH port is taken from `SSH_PORT`.
- For SSH firewall rules, `PANEL_IP` is required: IPv4 access only from `PANEL_IP`, IPv6 access from anywhere.
- SSL automation is controlled by `ENABLE_ACME_SSL`.
- For ACME issue, set at minimum: `ACME_EMAIL`, `ACME_DOMAIN`, and include `80` in `OPEN_TCP_PORTS`.
- Default ACME CA is `letsencrypt`; can be changed with `ACME_CA`.
- Use `ACME_RELOAD_CMD` to reload service after cert install (for example nginx/haproxy).
- If port 80 is already occupied, use `ACME_PRE_HOOK` / `ACME_POST_HOOK` to stop/start service around certificate issuance.
