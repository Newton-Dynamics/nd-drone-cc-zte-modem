# Docker registry pulls timing out — rogue USB-NIC DNS

## Symptom

```
failed to solve: DeadlineExceeded: failed to fetch anonymous token:
Get "https://auth.docker.io/token?...": dial tcp 192.168.50.46:443: i/o timeout
```

The dialed IP rotates through `192.168.50.x` (`.46`, `.20`, …) and is never
reachable. It is **intermittent** — most `getent` / `resolvectl` checks return
the correct Cloudflare IPs, so it looks like a transient network blip. It isn't.

## Root cause

A plug-in **USB ethernet NIC** (`enx*`, e.g. `enx344b50000000`) brings up a
network whose DHCP hands the system a **hijacking DNS resolver** (observed:
`192.168.0.1`). That resolver answers *every* hostname — `auth.docker.io`,
`registry-1.docker.io`, even `google.com` — with a dead `192.168.50.x` address
(a captive-portal / intercept appliance on its own subnet).

`systemd-resolved` has DNS on **multiple links** with no domain-routing rules:

```
Link 2 (enP8p1s0):        192.168.1.1     <- good WAN router
Link 9 (enx344b50000000): 192.168.0.1     <- hijacker
```

It queries all links in parallel and **uses the first reply** — a race. When
the hijacker wins, you get a `192.168.50.x` IP and the pull blackholes. The race
only corrupts **A (IPv4)** records (the hijacker leaves AAAA alone), which is why
`getent hosts auth.docker.io` sometimes returned *only* IPv6.

`dockerd`/BuildKit resolve registry hostnames via the **host** resolver (glibc →
`127.0.0.53`), so they inherit the race. Setting `dns` in `daemon.json` does
**not** fix this — that key only affects DNS *inside containers*.

## Fix (deployed by `nd_net_install.sh --install`)

1. **Primary — `neutralize_usb_nic_dns()`**: for every `enx*` NIC, set its NM
   connection `ipv4/ipv6.ignore-auto-dns yes` and `never-default yes` (plus a
   low `dns-priority`). The USB net stays usable for its own traffic but can no
   longer inject DNS or a default route into the host resolver. The WAN uplink
   (onboard eth / LTE) owns DNS. Mirrors the project rule that `enx*` USB NICs
   are second-class (same prefix `detect_eth_dev` excludes).

2. **Backstop — `install_docker_dns()`**: merge `dns: [8.8.8.8, 1.1.1.1]` from
   `docker-daemon-dns.json` into `/etc/docker/daemon.json` (jq merge — preserves
   any existing keys, idempotent) and restart docker. Helps container-internal
   resolution; not sufficient alone.

Both are idempotent and safe on machines with no USB NIC / no Docker.

## Verify

```bash
resolvectl dns                       # enx* link should show NO DNS server
for i in $(seq 30); do getent ahostsv4 auth.docker.io | awk 'NR==1{print $1}'; done
                                     # expect 0 results in 192.168.x
docker pull ubuntu:latest
```

## Not this

On L4T/Jetson, an extract step may still fail with
`failed to extract layer … Lchown … no such file or directory` on overlayfs.
That is a **separate** containerd/overlayfs-on-L4T storage issue, unrelated to
DNS — the layers download fine, proving the DNS path is healed.
