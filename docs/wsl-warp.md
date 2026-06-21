# Running on a WSL2 SEED laptop behind Cloudflare WARP

Host-side prep to run `coding-agent-sandbox` inside **WSL2 Ubuntu** on a Windows
**SEED laptop** where **Cloudflare WARP / Zero Trust** inspects all TLS. The
image change that makes the build trust the WARP CA lives in
[`../certs/`](../certs/README.md); this doc covers the **WSL/Docker host** setup
around it. (On a non-corporate Windows box, the simpler path is Docker Desktop —
see the main [README](../README.md#easiest-windows-setup).)

Each step below fixes a specific failure seen on a fresh SEED laptop.

## 1. WSL2 + Ubuntu

In an **admin PowerShell**:

```powershell
wsl --install -d Ubuntu
```

Reboot if it enables *VirtualMachinePlatform*, reopen Ubuntu, create your UNIX
user. Confirm: `uname -r` contains `WSL2`.

## 2. `/etc/wsl.conf` — metadata mount + systemd

```ini
[automount]
options = "metadata"

[boot]
systemd=true
```

- **`metadata`** — without it `chmod` fails on `/mnt/c`, so `git clone` of a
  Windows-side repo dies with *`chmod … Operation not permitted`*.
- **`systemd`** — cleanly manages the Docker daemon (if you use native
  `docker.io` instead of Docker Desktop).

Apply with a one-time restart from **PowerShell**: `wsl --shutdown`, then reopen
Ubuntu. Verify: `ps -p 1 -o comm=` prints `systemd`, and
`mount | grep ' /mnt/c '` shows `metadata`.

## 3. Prefer IPv4 (WARP's IPv6 is unreachable)

WARP hands back AAAA records but has no working IPv6 route, so `curl`/`nvm`/`apt`
stall trying IPv6 first. Force IPv4:

```bash
echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf
```

## 4. Docker

Either **Docker Desktop** with WSL integration enabled for the Ubuntu distro, or
native Engine inside WSL:

```bash
sudo apt-get update && sudo apt-get install -y docker.io   # matches even pre-release Ubuntu
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"                            # re-open the shell afterward
```

> Docker's own apt repo has no packages for very new/unreleased Ubuntu codenames;
> Ubuntu's `docker.io` tracks your release and is the reliable choice there.

The host already trusts the WARP CA (it's in the Windows/OS trust store), so
`docker pull` works. The **container** needs the CA separately — step 5.

## 5. Give the sandbox the WARP CA

The fetcher downloads the WARP CA, verifies it against a pinned SHA-256, and
writes it into `certs/`:

```bash
cd /path/to/coding-agent-sandbox
./certs/fetch-warp-ca.sh
./run.sh
```

(Works because the host already trusts WARP, so the HTTPS download validates.)
If you'd rather supply the cert yourself — from your IT portal — drop it in as
`certs/Cloudflare_CA.crt` instead. See [`../certs/README.md`](../certs/README.md)
for how the trust is wired into the image (build-time + runtime).

## Notes

- Keep your personal/work repos mapped to `C:\Users\<you>\{personal,work}`
  (e.g. `ln -s /mnt/c/Users/<you>/personal ~/personal`) if you want them visible in Windows;
  point `PERSONAL_DIR` / `WORK_DIR` in `.env` at those paths. Code on `/mnt/c` is
  slower than the Linux home — the `metadata` mount makes git *work* there, not
  *fast*.
- WARP interception is transparent to the container's egress, so no firewall
  change is needed; the proxy must still permit the sandbox's allowlisted
  destinations (add any it blocks via `EXTRA_ALLOWED_DOMAINS`).
