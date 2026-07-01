# v2e-compose

The application layer of the v2e lab: Docker Compose stacks fronted by **Traefik v3**,
which terminates TLS using **Let's Encrypt** wildcard certs obtained over the **Cloudflare
DNS-01** challenge (no inbound ports). COMPOSE-1 ships Traefik + a `whoami` test service.

## Layout

Each service is its own Compose project in its own folder, all sharing one external
`frontend` network:

```
traefik/compose.yml         Traefik (edge, TLS, routing)
traefik/data/certs/         ACME storage (acme-staging.json / acme.json), 0600, gitignored
whoami/compose.yml          test service proving the cert path
.env / .env.example         non-secret config (DOMAIN, ACME_EMAIL, CERT_RESOLVER)
secrets.sops.yaml(.example) the one secret (CF_DNS_API_TOKEN), SOPS-encrypted
Makefile                    local bootstrap + deploy
```

**Networks — two tiers.** `frontend` = edge (Traefik ↔ routed services). `backend`
(`internal: true`, no egress) is the data tier for stateful services and arrives in
COMPOSE-3 (Semaphore ↔ Postgres); COMPOSE-1 only needs `frontend`.

## Prerequisites

- Docker Engine + Compose v2.
- `sops` and `age` (baked into the v2e images; `brew install sops age` locally).
- A domain on Cloudflare (here `v2e.sh`) and a **scoped** API token: **Zone:Read + DNS:Edit**. Not the global key.
- An age keypair (created once for the whole v2e SOPS setup — D-1). Check:
  `echo $SOPS_AGE_KEY_FILE` or `ls ~/.config/sops/age/keys.txt`. If absent:
  `age-keygen -o ~/.config/sops/age/keys.txt`, then put your **public** key
  (`age-keygen -y ~/.config/sops/age/keys.txt`) into `.sops.yaml`.

## First run (local / standalone)

```bash
make bootstrap          # creates the docker network (frontend), .env, certs dir, and secrets.sops.yaml
$EDITOR .env            # set DOMAIN + ACME_EMAIL (CERT_RESOLVER stays 'staging' for now)
make up                 # deploys traefik + whoami against the STAGING CA
make logs               # watch the ACME order complete
```

Test (point the host at your Docker host if there's no public record):

```bash
echo "127.0.0.1 whoami.v2e.sh" | sudo tee -a /etc/hosts   # local test only
curl -vk https://whoami.v2e.sh     # whoami body; issuer = (STAGING) Let's Encrypt
curl -I  http://whoami.v2e.sh      # 301 -> https
```

When staging looks good, flip to the real CA:

```bash
make prod               # CERT_RESOLVER=production; production resolver, separate acme.json
curl -v https://whoami.v2e.sh      # no -k; issuer = Let's Encrypt
```

Rollback is instant — `CERT_RESOLVER=staging` again (the two resolvers keep separate
storage, so neither flip wipes the other).

## Authentication (TinyAuth)

COMPOSE-2 puts a TinyAuth forward-auth layer in front of protected services.

- **Protected:** the Traefik dashboard — `https://traefik.v2e.sh` (behind login).
- **Public:** `whoami.v2e.sh` and the TinyAuth login page `tinyauth.v2e.sh`.
- **SSO:** the session cookie is set on `.v2e.sh`, so one login covers every protected
  `*.v2e.sh` subdomain (COMPOSE-3's services inherit it).

### Create the signing secret + a user

Both live in `secrets.sops.yaml` (edit with `sops secrets.sops.yaml`):

```bash
openssl rand -hex 16                                                   # -> TINYAUTH_SECRET (32 chars)
docker run --rm -it ghcr.io/steveiliop56/tinyauth:v5.0.7 user create   # -> TINYAUTH_AUTH_USERS (user:bcrypt)
```

`make up` deploys tinyauth alongside traefik/whoami. Then:

- `https://traefik.v2e.sh` → redirected to the TinyAuth login → valid creds → dashboard.
- `https://whoami.v2e.sh` → loads with no prompt (public).

### Protecting another service

Add one label to its router: `traefik.http.routers.<name>.middlewares=auth@docker`
(chain with `secure-headers@docker` as needed). The login page must **never** carry
`auth` — it cannot gate itself.

### Swapping to Authelia later

The middleware is named `auth` (not `tinyauth`) on purpose: replace the tinyauth stack with
Authelia (+ Valkey), define a middleware also named `auth` pointing at Authelia's verify
endpoint, and every protected router (`middlewares=auth@docker`) keeps working unchanged.

## How variables reach the container

The compose files declare `${DOMAIN}`, `${ACME_EMAIL}`, `${CERT_RESOLVER}`, and
`${CF_DNS_API_TOKEN}`. Compose interpolates these from the **process environment**, so the
source is pluggable:

- **Local:** `.env` provides the config; `sops exec-env secrets.sops.yaml '…'` (wrapped by
  `make up`) adds the token. Only `CF_DNS_API_TOKEN` is injected *into* the Traefik
  container (via `environment:`); the rest become flag/label text at launch.
- **Automated lab (ANS-3):** you set all values **once, locally, before `terraform
  apply`**, in the SOPS-managed group_vars (the same D-1 file that carries the token).
  Terraform ships it; Ansible decrypts it; ANS-3 deploys under `sops exec-env`. **No `.env`
  is copied to the host** — the values land directly in the container environment.

## Cloudflare / DNS-01 notes

- **Wildcard:** one `v2e.sh` + `*.v2e.sh` cert (anchored on the whoami router in COMPOSE-1;
  re-anchored onto the authenticated dashboard router in COMPOSE-2).
- **Gray-cloud:** any *public* A/AAAA record for an internal service must be **DNS-only (gray cloud)** — orange-cloud serves Cloudflare's edge cert, not LE, and can't reach a private IP. The `lab.v2e.sh` tunnel record stays proxied (different record).
- DNS-01 needs **no** inbound ports and no public record for the cert itself.
- The propagation pre-check is pinned to `1.1.1.1:53,1.0.0.1:53` to avoid split-horizon DNS.
- **Staging first** — production LE allows only 5 duplicate certs/week; the resolver split
  means staging mistakes never burn that quota.

## Security posture (COMPOSE-1) and the hardening backlog

Applied now: `no-new-privileges` on every service; read-only `docker.sock`;
`exposedByDefault=false`; exact image tags; non-HSTS security headers.

**Caveat — `:ro` on `docker.sock` is largely cosmetic:** it makes the socket *file*
read-only but does not stop Docker API writes over it. Real protection is the socket-proxy
below.

**COMPOSE-1.x hardening (deferred, all additive):**
- `tecnativa/docker-socket-proxy` (Traefik talks to a read-only proxy; the real socket
  never touches Traefik) — removes the caveat above.
- `cap_drop: ALL` (+ `NET_BIND_SERVICE` for Traefik), read-only root FS + `tmpfs`.
- Image digest pins (on top of the current tags).
- **HSTS** on the `secure-headers` middleware — only after a production cert is active
  (HSTS + a staging cert makes the cert warning un-bypassable).

## How the lab deploys this (ANS-3)

ANS-3 creates the `frontend` network, then runs `community.docker.docker_compose_v2` per
stack with the environment supplied from the sops-decrypted group_vars (no host `.env`
required). The variable contract above is mirrored as group_vars keys.
