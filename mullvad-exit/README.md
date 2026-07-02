# mullvad-exit — Mullvad exit node via gluetun + Tailscale

A privacy exit node: `gluetun` holds a Mullvad WireGuard tunnel, and a Tailscale
sidecar shares its network namespace and advertises itself as an exit node. Any
tailnet device that picks it routes its internet traffic out through Mullvad. It
appears in the exit-node picker as **`mullvad`**, next to the residential **`home`**
exit (the `home` node egresses your real WAN; this one egresses Mullvad).

Why Docker (and not on the host): Mullvad's WireGuard rewrites the whole routing
table of wherever it runs. In a shared container namespace that's contained — it
never touches the host's routes or DNS. Running Mullvad directly on a host would
hijack it (the exact thing that breaks `int.v2e.sh` when the Mullvad app runs on the
Mac). So: **use Docker for the Mullvad exit, on-host for the residential one.**

## What you need (one-time)

1. A Mullvad account. In the account portal: **WireGuard configuration → generate a
   new key → pick a location → download the `.conf`**. From that file take:
   - `PrivateKey=` → `MULLVAD_WIREGUARD_PRIVATE_KEY`
   - `Address=`   → `MULLVAD_WIREGUARD_ADDRESSES` (e.g. `10.64.222.21/32`)
   > The key on the *Manage devices* page is **not** the private key — you must
   > generate a config to get it.
2. A reusable Tailscale auth key (the lab already has one in SOPS).

## Run it in the lab (SOPS-driven)

Secrets live in SOPS, never in this dir:
- `mullvad_wireguard_private_key`, `mullvad_wireguard_addresses`, `tailscale_authkey`
  in `v2e-tf/secrets.sops.yaml` (shipped to the node, rendered into the shared `.env`
  by the `compose_stack` role via `env.j2`).
- `mullvad_server_cities` (non-secret) in the node's group_vars.

Enable: add `mullvad-exit` to that node's `compose_stack_stacks` (group_vars), put the
two Mullvad values in SOPS, converge. Then **approve the new `mullvad` exit node in
the Tailscale admin console** (same one-time approval as any exit node).

## Run it standalone on a VPS

```bash
cp .env.example .env && $EDITOR .env      # fill Mullvad creds + Tailscale key
docker compose up -d
```
Then approve `mullvad` in the Tailscale console. Nothing else on the VPS is exposed —
only the outbound WireGuard + Tailscale connections.

## Verify

```bash
docker compose logs gluetun | grep -i "public ip"      # should be a Mullvad IP
# from another tailnet device, after selecting the exit node:
curl https://am.i.mullvad.net/connected                 # "You are connected to Mullvad"
```

## Troubleshooting — forwarded traffic doesn't flow

Two independent root causes were hit on first deploy (2026-07); either alone
blackholes the exit node. Check the FORWARD counters first to tell them apart:
`docker compose exec gluetun iptables -L FORWARD -v -n` — **nonzero drops** point
at cause 1 (firewall backends), **all-zero counters** at cause 2 (policy routing:
packets die before FORWARD).

**Cause 2 — FIREWALL_OUTBOUND_SUBNETS misroute (all counters zero):** setting
`FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10` makes gluetun install
`ip rule 99: to 100.64.0.0/10 lookup 199` with `100.64.0.0/10 via <eth0 gw>` —
higher priority than tailscaled's table 52 (prio 5270). Replies to exit-node
clients get routed into the docker bridge instead of back through tailscale0,
and strict `rp_filter=1` drops the inbound leg too (reverse lookup says eth0,
packet arrived on tailscale0). Fix: don't set that variable at all — the sidecar
needs no tailnet bypass (its peer/DERP traffic travels inside the VPN tunnel).
Live check: `docker compose exec gluetun ip rule` must NOT list a
`to 100.64.0.0/10` rule.

**Cause 1 — split firewall backends:** the tailscale sidecar (Alpine)
programs its forwarding/SNAT rules via **iptables-legacy**, while gluetun's
kill-switch uses **iptables-nft** with `FORWARD` policy `DROP`. The kernel evaluates
both backends, so tailscale's own rules pass in legacy and the packet still dies at
gluetun's nft `DROP`. Symptom: `tailscale ping mullvad` pongs, but a device selecting
the exit node has zero internet (even `ping 1.1.1.1` blackholes).

The shipped fix is `post-rules.txt` (mounted to `/iptables/post-rules.txt`), which
gluetun re-applies on every firewall rebuild — it opens `tailscale0<->tunnel`
forwarding and masquerades out the tunnel, on the nft side. It lists both `tun0`
(the live interface on v3.41.1) and `wg0` (gluetun's source default for WireGuard)
— rules naming an absent interface are legal no-ops, so this survives an upgrade
renaming the interface. Diagnosis, if it recurs:

1. Confirm forwarding: `docker compose exec gluetun sysctl net.ipv4.ip_forward` → 1.
2. Compare backends: `docker compose exec gluetun sh -c 'iptables -S FORWARD; iptables-legacy -S FORWARD'`
   — nft must show the two `ACCEPT`s from post-rules.txt, not just `-P FORWARD DROP`.
3. Same live (post-rules.txt does this permanently):
   `docker compose exec gluetun sh -c 'iptables -A FORWARD -i tailscale0 -o tun0 -j ACCEPT; iptables -A FORWARD -i tun0 -o tailscale0 -j ACCEPT; iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE'`
4. Last resort: set `FIREWALL=off` on gluetun (loses the kill-switch — less private;
   prefer the post-rules fix).
