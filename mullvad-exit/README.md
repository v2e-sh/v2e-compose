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

Modern Tailscale sets up its own exit-node SNAT, so the two containers above are
normally enough. If a device selects the exit node but gets no internet:
1. Confirm forwarding: `docker compose exec gluetun sysctl net.ipv4.ip_forward` → 1.
2. Add an explicit masquerade in gluetun's namespace:
   `docker compose exec gluetun sh -c 'iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE'`
   — if that fixes it, make it permanent with a tiny post-rules helper.
3. Last resort: set `FIREWALL=off` on gluetun (loses the kill-switch — less private;
   prefer the masquerade fix).
