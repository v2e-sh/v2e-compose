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

## Design note — the sidecar MUST run in userspace (netstack) mode

`TS_USERSPACE=true` is load-bearing, not a fallback. Kernel-mode forwarding
(`TS_USERSPACE=false`) was tried first and fails against gluetun on **three
independent fronts**, each of which alone blackholes the exit (verified live,
2026-07, gluetun v3.41.1 + tailscale v1.98.4):

1. **Split iptables backends** — the tailscale image programs `iptables-legacy`
   while gluetun's kill-switch (`FORWARD` policy `DROP`) uses `iptables-nft`;
   the kernel enforces both, so tailscale's own ACCEPT/SNAT rules don't help.
2. **`FIREWALL_OUTBOUND_SUBNETS=100.64.0.0/10`** (since removed) — gluetun turns
   it into `ip rule 99: to 100.64.0.0/10 lookup 199` → `via <docker bridge>`,
   hijacking the return path to exit clients ahead of tailscaled's table 52.
3. **gluetun's master policy rule** — `101: not fwmark 0xca6c lookup 51820`
   (its "everything unmarked goes into the VPN" wg-quick rule) also outranks
   table 52, so even with (1) and (2) fixed, reply packets to `100.x` route
   toward `tun0` instead of `tailscale0`, and strict `rp_filter=1` drops the
   inbound leg symmetrically. Telltale: ALL `FORWARD` counters stay zero
   (`docker compose exec gluetun iptables -L FORWARD -v -n`).

In netstack mode none of this machinery is involved: tailscaled decrypts exit
traffic in userspace and re-emits it as **ordinary sockets in the shared netns**,
which follow gluetun's own routing (rule 101 → VPN table) out the Mullvad tunnel —
the exact path gluetun is designed to give container-local traffic. The
kill-switch keeps working: socket egress is only permitted via the tunnel, so a
dropped VPN fails closed instead of leaking via `eth0`.

Operational caveats of a userspace exit (all fine for a privacy exit):
- Only **TCP and UDP** are forwarded (netstack terminates and re-originates flows);
  ping is synthesized by tailscaled, other IP protocols (GRE/SCTP) won't pass.
- Throughput is netstack-bound and, behind Mullvad (no port forwarding), clients
  often connect via DERP relay rather than direct — expect modest speeds. If
  downloads are pathologically slow, try `WIREGUARD_MTU=1450` on gluetun
  (double-WireGuard MTU stacking, see gluetun discussion #2201).
- If you ever need kernel-mode speeds, don't share a netns with gluetun; run
  WireGuard and tailscaled on separate hosts/netns you control.

Diagnosis if forwarding regresses: check the sidecar really runs userspace
(no `tailscale0` interface in `docker compose exec gluetun ip -br addr`), then
check gluetun's `ip rule` for anything outranking its VPN rule. Last resort is
`FIREWALL=off` on gluetun (loses the kill-switch; prefer fixing the real cause).
