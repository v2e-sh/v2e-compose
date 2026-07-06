# Authelia SSO — migration record (COMPLETED 2026-07-06)

Replaced TinyAuth's Traefik forward-auth **and** added an OIDC provider so Arcane and Grafana get real SSO (closed H3 — Arcane's default local password). Drafted + adversarially reviewed against the Authelia **4.39** schema.

**Status: DONE.** The migration is fully deployed and verified — TinyAuth is decommissioned and Authelia is the sole auth gate (whoami/traefik-dash/uptime/semaphore on `authelia@docker`; Grafana + Arcane on native OIDC). This document is kept as the historical design + migration record; the live state is described in the docs site and HANDOVER. The diffs below were applied during the cutover.

## Review verdict: `needs-fixes`

The 4.39 schema is valid (no deprecated keys — `jwks`, `/api/authz/forward-auth`, `identity_validation.reset_password.jwt_secret`, `session.cookies[].default_redirection_url` all confirmed current). Must-fix items before any deploy:

**Migration / lockout risks**
- MIDDLEWARE RENAME CUTOVER (highest risk): the forward-auth middleware changes name from 'auth@docker' (tinyauth) to 'authelia@docker'. Every protected app router still references 'auth@docker'. The moment the tinyauth stack is torn down, 'auth@docker' ceases to exist and Traefik errors on any router still pointing at it — those services become inaccessible. Do NOT remove tinyauth until every app router has been repointed to 'authelia@docker' AND Authelia is verified logging users in. Run both stacks side by side during migration.
- PLACEHOLDER ADMIN HASH = TOTAL LOCKOUT: users_database.yml ships a REPLACE_WITH_SALT/REPLACE_WITH_HASH placeholder and admin is the ONLY user. If deployed unreplaced, the argon2id hash is invalid, nobody can authenticate, so every one_factor-gated app is unreachable AND grafana/arcane OIDC can't complete (OIDC needs an authenticated Authelia session). Combined with the tinyauth teardown this is a full-lab lockout. Generate + insert a real hash (docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password ...) BEFORE first deploy.
- OIDC APPS DOUBLE-GATED / REDIRECT LOOP: if the grafana.int.v2e.sh or arcane.int.v2e.sh routers also carry the authelia@docker forward-auth middleware, users are forced through one_factor forward-auth AND then OIDC — redundant and can loop. OIDC relying-party routers must NOT have the forward-auth middleware. These routers aren't in the provided files — verify they drop it.
- default_policy: 'deny' with only 'auth.int.v2e.sh: bypass' and '*.int.v2e.sh: one_factor'. The wildcard matches only single-label subdomains — a deeper host like a.b.int.v2e.sh, or the apex int.v2e.sh, is NOT matched and is denied outright if it ever gets the authelia middleware. Confirm every protected host is a single-label subdomain of int.v2e.sh.
- COOKIE DOMAIN / RE-LOGIN: cookie domain int.v2e.sh is correct (parent of both auth portal and apps) — good. But any protected app on a different registrable domain would never receive the session cookie and would infinite-redirect. Also all existing TinyAuth sessions are invalidated at cutover; every user must re-login (expected, not a bug).
- IN-MEMORY SESSIONS: no redis block → sessions live in memory and drop on every Authelia container restart (including the migration itself, image pulls, config edits) forcing re-login. OIDC consent/refresh tokens persist in SQLite so OIDC survives restart; only the browser session cookie dies. Acceptable per the draft, but expect immediate re-auth during/after deploy.

**Schema / functional notes**
- No DEPRECATED or invalid 4.39 keys found — the config parses. Verified against live docs: jwks[].{key_id,algorithm,use} + key-via-_FILE is the CURRENT form (legacy identity_providers.oidc.issuer_private_key is gone, draft correctly avoids it); session.cookies[].default_redirection_url is valid and deprecates the old global key; identity_validation.reset_password.jwt_secret is the correct 4.38+ replacement for top-level jwt_secret; server.address 'tcp://:9091/' is valid 4.38+ syntax; claims_policies.NAME.id_token as a list of claim names is correct.
- FUNCTIONAL (not a parse error but wrong behavior): the ARCANE client requests scope 'groups' but has NO claims_policy, so Authelia only surfaces the groups claim at the userinfo endpoint, never in the id_token. Authelia's own Arcane reference client uses only 'openid email profile' (no groups scope at all). Arcane's admin mapping relies on OIDC_ADMIN_CLAIM=groups / OIDC_ADMIN_VALUE=arcane-admins; if Arcane reads groups from the id_token (as Grafana must, per Authelia's guide 'does not honor the expected process to retrieve the claims'), arcane-admins mapping silently fails and the admin lands as a normal user. Fix: add claims_policy: 'with_groups' to the arcane client (index 0) OR positively verify Arcane fetches userinfo. Be defensive — give arcane the same policy as grafana.
- Grafana client adds scope 'offline_access' + refresh_token grant, but a refresh token is inert unless the Grafana RP sets GF_AUTH_GENERIC_OAUTH_USE_REFRESH_TOKEN=true. The provided env.j2 diff only renders GRAFANA_OIDC_CLIENT_SECRET; confirm the grafana stack also sets use_refresh_token, role_attribute_path (to map grafana-admins/grafana-editors), auth/token/api URLs, and AUTH_STYLE=InHeader (matches token_endpoint_auth_method: client_secret_basic). Not a blocker, but offline_access is pointless otherwise.
- Minor: claims_policies.with_groups.id_token lists 'email_verified' which Authelia's Grafana reference omits (it uses email,name,groups,preferred_username). Harmless, just non-standard vs the doc.

**Secret handling**
- All FIVE required Authelia secrets are present and env-injected, none hardcoded in YAML: session secret, storage.encryption_key, identity_validation.reset_password.jwt_secret, oidc.hmac_secret, and the RS256 jwks key (via ..._JWKS_0_KEY_FILE pointing at the mounted PEM). Client secrets are correctly HASHED (pbkdf2-sha512) in Authelia with plaintext going only to the RP apps + SOPS. The 'secret in both env and YAML => refuse to start' concern is correctly handled: every secret key is omitted from configuration.yml. Good.
- users_database.yml is mounted from a GIT-TRACKED path (./config/users_database.yml). The template is fine, but the DEPLOYED file must contain a real argon2id admin hash — if the operator edits it in place it risks being committed to the repo. Recommend rendering users_database.yml out-of-band via Ansible/SOPS (like oidc.issuer.pem) and gitignoring it, rather than editing a tracked file.
- The PEM provisioning task is NOT YET IMPLEMENTED — the env.j2 note explicitly says to 'extend the compose_stack role with a copy/template task' for oidc.issuer.pem. If that task is missing at deploy time, Authelia has no jwks signing key and crash-loops on startup (OIDC mandatory: at least one RS256 sig key). Ensure the PEM is materialised (mode 0600) before deploy and the key is a real >=2048-bit RSA key.
- MINOR hardening: the per-client PLAINTEXT secret (ARCANE_OIDC_CLIENT_SECRET / GRAFANA_OIDC_CLIENT_SECRET) is rendered into the same /opt/v2e-compose/.env as its own pbkdf2 HASH. This partly defeats the point of hashing in Authelia (a config leak there shouldn't reveal plaintext) since both sit in one file on disk. Not a blocker given SOPS-at-rest, but consider scoping plaintext only to the RP stack's env.
- The replace('$','$$') escape in env.j2 is correctly load-bearing for the pbkdf2 hashes (literal $ in $pbkdf2-sha512$...) — compose would otherwise mangle them. Same proven pattern as the tinyauth bcrypt hash. Correct.

> The Arcane `claims_policy: 'with_groups'` fix from the review IS already applied in `config/configuration.yml`.

## Secrets to generate (into SOPS `group_vars/all`)

- authelia_session_secret — 64-char random. `docker run --rm authelia/authelia:4.39.20 authelia crypto rand --length 64 --charset alphanumeric` (or `openssl rand -hex 32`). SOPS key: authelia_session_secret.
- authelia_storage_encryption_key — 64-char random (encrypts sensitive columns in db.sqlite3). Same command as above. SOPS key: authelia_storage_encryption_key.
- authelia_reset_password_jwt_secret — 64-char random (signs password-reset JWTs). Same command. SOPS key: authelia_reset_password_jwt_secret.
- authelia_oidc_hmac_secret — 64-char random (signs OIDC tokens). Same command. SOPS key: authelia_oidc_hmac_secret.
- authelia_oidc_issuer_key — RS256 private key PEM (the OIDC signing key). `docker run --rm -v "$PWD:/keys" authelia/authelia:4.39.20 authelia crypto pair rsa generate --bits 4096 --directory /keys` -> use the generated private key. Stored in SOPS as authelia_oidc_issuer_key and materialised to authelia/config/secrets/oidc.issuer.pem (mode 0600, gitignored). NOT placed in .env (multiline PEM).
- authelia_oidc_arcane_client_secret (+ _hash) — one secret, two forms. Generate the pair together: `docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986`. Store the 'Random Password' as authelia_oidc_arcane_client_secret (goes to Arcane, plaintext) and the 'Digest' ($pbkdf2-sha512$...) as authelia_oidc_arcane_client_secret_hash (goes to Authelia).
- authelia_oidc_grafana_client_secret (+ _hash) — same pbkdf2 generate command; plaintext -> authelia_oidc_grafana_client_secret (Grafana), hash -> authelia_oidc_grafana_client_secret_hash (Authelia).
- admin user argon2id password hash (for users_database.yml, not a .env secret) — `docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'`. Paste the $argon2id$... output into authelia/config/users_database.yml.

## Migration steps (no-lockout ordering)

1. Generate every secret above; add them to the SOPS group_vars/all.yml. Provision the RS256 key to authelia/config/secrets/oidc.issuer.pem (mode 0600) and add config/secrets/ to .gitignore. Set your admin argon2id hash in authelia/config/users_database.yml.
2. Add the authelia stack files + the group_vars/services.yml entries. Keep `tinyauth` in compose_stack_stacks and keep every app on `auth@docker` for now — nothing loses its gate.
3. Deploy the authelia stack. Verify https://auth.int.v2e.sh loads and you can log in as admin. If you plan to use two_factor anywhere, enroll TOTP now (read the enrollment link with `docker compose exec authelia cat /data/notification.txt`).
4. Cut over ONE low-risk forward-auth app first: change whoami's router middleware from `auth@docker` to `authelia@docker`, redeploy, and confirm the full login->redirect->access loop works. Keep a separate logged-in tinyauth session open as break-glass.
5. Cut over the remaining forward-auth apps the same way: traefik dashboard and uptime-kuma (`auth@docker` -> `authelia@docker`). Verify each individually.
6. Move Grafana to OIDC: apply the observability diff, redeploy. Test SSO login while GF_SECURITY_ADMIN_* local login is still enabled (break-glass). Confirm a `grafana-admins` user maps to Admin.
7. Move Arcane to OIDC: apply the arcane diff but FIRST redeploy with AUTH_LOCAL_ENABLED still true (or omitted) and verify OIDC login + arcane-admins->role_admin works. Only then set AUTH_LOCAL_ENABLED=false (or toggle it in Settings > Security if the env var proves unsupported) and redeploy.
8. Once every app authenticates via Authelia (forward-auth or OIDC) and is verified, remove `tinyauth` from compose_stack_stacks, drop tinyauth_auth_users from required_secrets, and tear down the tinyauth stack.
9. Optional hardening after things are stable: raise sensitive hosts (traefik dashboard, arcane) to two_factor in access_control; consider a Redis session backend if in-memory session loss on restart is annoying.

## App-side & ansible changes (apply during migration)

Traefik-fronted apps that stay on forward-auth (traefik dashboard, uptime-kuma, whoami) must switch their router middleware label from `auth@docker` to `authelia@docker` — the endpoint/port change and required trustForwardHeader=true are handled inside the new middleware definition, so no other app changes are needed and the Remote-* response headers are identical. Apps moving to native SSO (Grafana, Arcane) instead DROP the forward-auth middleware entirely (router keeps only `secure-headers@docker`) because OIDC now authenticates them directly; they gain the OIDC/OAuth env blocks. Ops/repo changes: add authelia/config/secrets/ to .gitignore and provision oidc.issuer.pem there out-of-band (the compose_stack role currently only renders .env, so writing this PEM needs a new ansible copy/template task from SOPS, or a manual mode-0600 drop). The authelia-data named volume holds db.sqlite3 + notification.txt. Keep Grafana's GF_SECURITY_ADMIN_* and (initially) Arcane local login as break-glass until SSO is proven. Order matters in configuration.yml: clients index 0=arcane, 1=grafana must line up with the AUTHELIA_..._CLIENTS_0/1_CLIENT_SECRET env overrides.

### `v2e-ansible/roles/compose_stack/templates/env.j2 (DIFF — append after the GRAFANA_ADMIN_PASSWORD / mullvad block)`

_env.j2 additions rendering the AUTHELIA_* secrets + per-client plaintext OIDC secrets into /opt/v2e-compose/.env. Follows the exact house pattern: `| default('') | replace('$', '$$')` (the pbkdf2 hashes contain literal `$`, so the `$$` escape is load-bearing — without it compose mangles `$pbkdf2-sha512$...`). default('') keeps rendering working when the authelia stack isn't enabled; each compose guards with ${VAR:?}._

```
{# Authelia SSO stack — secrets injected as AUTHELIA_* env overrides + per-client OIDC
   secrets. default('') keeps rendering working when the authelia stack isn't enabled;
   each compose guards with ${VAR:?}. The pbkdf2 hashes contain literal `$`, so the
   replace('$','$$') escape is REQUIRED (same reason as the tinyauth bcrypt hash). #}
AUTHELIA_SESSION_SECRET={{ authelia_session_secret | default('') | replace('$', '$$') }}
AUTHELIA_STORAGE_ENCRYPTION_KEY={{ authelia_storage_encryption_key | default('') | replace('$', '$$') }}
AUTHELIA_RESET_PASSWORD_JWT_SECRET={{ authelia_reset_password_jwt_secret | default('') | replace('$', '$$') }}
AUTHELIA_OIDC_HMAC_SECRET={{ authelia_oidc_hmac_secret | default('') | replace('$', '$$') }}
{# Client secret HASHES go to the Authelia container (clients index 0=arcane, 1=grafana). #}
AUTHELIA_OIDC_ARCANE_CLIENT_SECRET_HASH={{ authelia_oidc_arcane_client_secret_hash | default('') | replace('$', '$$') }}
AUTHELIA_OIDC_GRAFANA_CLIENT_SECRET_HASH={{ authelia_oidc_grafana_client_secret_hash | default('') | replace('$', '$$') }}
{# Matching PLAINTEXT client secrets go to the RP apps (arcane / grafana stacks). #}
ARCANE_OIDC_CLIENT_SECRET={{ authelia_oidc_arcane_client_secret | default('') | replace('$', '$$') }}
GRAFANA_OIDC_CLIENT_SECRET={{ authelia_oidc_grafana_client_secret | default('') | replace('$', '$$') }}

NOTE (not an env.j2 line): the RS256 issuer private key (authelia_oidc_issuer_key) is a
multiline PEM and CANNOT be an env-file value. It must be materialised as the mounted file
v2e-compose/authelia/config/secrets/oidc.issuer.pem (gitignored). Provision it either by
extending the compose_stack role with a `copy`/`template` task that writes the SOPS-decrypted
key to that path (mode 0600), or a dedicated ansible task. See migration_steps + open_questions.
```

### `v2e-ansible/inventory/group_vars/services.yml (DIFF)`

_Register the authelia stack in the deploy list and add its fail-fast required_secrets. Insert `authelia` in compose_stack_stacks BEFORE tinyauth is removed (both run during cutover). The oidc_issuer_key + client-secret pairs are added to the presence check._

```
# --- compose_stack_required_secrets: ADD these entries ---
compose_stack_required_secrets:
  - cf_dns_api_token
  - tinyauth_auth_users            # keep until tinyauth is decommissioned (see migration_steps)
  # Authelia SSO stack (SSO-1):
  - authelia_session_secret
  - authelia_storage_encryption_key
  - authelia_reset_password_jwt_secret
  - authelia_oidc_hmac_secret
  - authelia_oidc_issuer_key                    # RS256 PEM -> written to config/secrets/oidc.issuer.pem
  - authelia_oidc_arcane_client_secret          # plaintext (Arcane app)
  - authelia_oidc_arcane_client_secret_hash     # pbkdf2 hash (Authelia)
  - authelia_oidc_grafana_client_secret         # plaintext (Grafana app)
  - authelia_oidc_grafana_client_secret_hash    # pbkdf2 hash (Authelia)

# --- compose_stack_stacks: ADD `authelia`. Place it before arcane/observability so the
#     OIDC provider is up before the RPs, and keep `tinyauth` until cutover is done. ---
compose_stack_stacks:
  - traefik
  - tinyauth        # remove only after every app is moved to authelia@docker / OIDC
  - authelia        # SSO-1: forward-auth + OIDC provider
  - whoami
  - semaphore
  - arcane
  - observability
```

### `v2e-compose/arcane/compose.yml (DIFF — arcane service environment + router middleware)`

_Arcane moves to native OIDC SSO against Authelia and drops the forward-auth middleware (OIDC now gates it). Adds OIDC_* env (plaintext secret via ${ARCANE_OIDC_CLIENT_SECRET:?} guard), group->role mapping, auto-redirect, and AUTH_LOCAL_ENABLED=false. Router middleware changes from `auth@docker,secure-headers@docker` to just `secure-headers@docker`._

```
# 1) In the `arcane` service `environment:` block, ADD (keep existing APP_URL etc.):
      - OIDC_ENABLED=true
      - OIDC_ISSUER_URL=https://auth.${INTERNAL_DOMAIN}       # no trailing slash
      - OIDC_CLIENT_ID=arcane
      - OIDC_CLIENT_SECRET=${ARCANE_OIDC_CLIENT_SECRET:?set via the SOPS-rendered .env (authelia_oidc_arcane_client_secret)}
      - OIDC_SCOPES=openid email profile groups
      - OIDC_GROUPS_CLAIM=groups
      - OIDC_ROLE_MAPPINGS=[{"claimValue":"arcane-admins","roleId":"role_admin"}]
      # Skip the local login page and bounce straight to Authelia.
      - OIDC_AUTO_REDIRECT_TO_PROVIDER=true
      # Disable username/password login once OIDC is verified. NOTE: this env var is NOT in
      # the current Arcane docs (the documented path is the UI toggle Settings > Security >
      # OIDC). Included per request; see open_questions — verify or fall back to the UI.
      - AUTH_LOCAL_ENABLED=false

# 2) In the `arcane` router labels, CHANGE the middleware line (drop forward-auth; OIDC
#    now authenticates Arcane directly). Was:
#      - traefik.http.routers.arcane.middlewares=auth@docker,secure-headers@docker
#    Now:
      - traefik.http.routers.arcane.middlewares=secure-headers@docker
```

### `v2e-compose/observability/compose.yml (DIFF — grafana service environment + router middleware)`

_Grafana moves to generic OAuth (Authelia) and drops forward-auth. Adds GF_AUTH_GENERIC_OAUTH_* with plaintext secret via ${GRAFANA_OIDC_CLIENT_SECRET:?} guard, explicit Authelia OIDC endpoints, JMESPath role mapping from groups, and server-admin assignment. Keeps GF_SECURITY_ADMIN_* as break-glass local login (no lockout). Router middleware changes from `auth@docker,secure-headers@docker` to `secure-headers@docker`._

```
# 1) In the `grafana` service `environment:` block, ADD (keep existing GF_SECURITY_ADMIN_*
#    as a break-glass local login, and the existing GF_SERVER_ROOT_URL):
      - GF_AUTH_GENERIC_OAUTH_ENABLED=true
      - GF_AUTH_GENERIC_OAUTH_NAME=Authelia
      - GF_AUTH_GENERIC_OAUTH_CLIENT_ID=grafana
      - GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${GRAFANA_OIDC_CLIENT_SECRET:?set via the SOPS-rendered .env (authelia_oidc_grafana_client_secret)}
      - GF_AUTH_GENERIC_OAUTH_SCOPES=openid profile email groups
      - GF_AUTH_GENERIC_OAUTH_AUTH_URL=https://auth.${INTERNAL_DOMAIN}/api/oidc/authorization
      - GF_AUTH_GENERIC_OAUTH_TOKEN_URL=https://auth.${INTERNAL_DOMAIN}/api/oidc/token
      - GF_AUTH_GENERIC_OAUTH_API_URL=https://auth.${INTERNAL_DOMAIN}/api/oidc/userinfo
      - GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH=preferred_username
      - GF_AUTH_GENERIC_OAUTH_GROUPS_ATTRIBUTE_PATH=groups
      - GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(groups[*], 'grafana-admins') && 'Admin' || contains(groups[*], 'grafana-editors') && 'Editor' || 'Viewer'
      - GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN=true
      # Optional: bounce straight to Authelia instead of showing Grafana's login form.
      # - GF_AUTH_OAUTH_AUTO_LOGIN=true

# 2) In the `grafana` router labels, CHANGE the middleware line (drop forward-auth; OAuth
#    now authenticates Grafana directly). Was:
#      - traefik.http.routers.grafana.middlewares=auth@docker,secure-headers@docker
#    Now:
      - traefik.http.routers.grafana.middlewares=secure-headers@docker
```

## Open questions (need your call)

- Env-index override for client secret hashes: does Authelia 4.39 reliably map AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET / _1_ onto the clients list? If it does not, the fallback is to place the pbkdf2 hash placeholders directly in configuration.yml (hashes are non-reversible) or use the ..._CLIENT_SECRET_FILE form with mounted files. Worth a quick `authelia validate-config` / boot test.
- Arcane AUTH_LOCAL_ENABLED=false is NOT in the current Arcane docs (the documented way to disable local login is the UI toggle Settings > Security > OIDC). Confirm the real env var name or plan to flip it in the UI after OIDC verification.
- claims_policies schema: confirm the 4.39 `claims_policies.<name>.id_token: [groups, email, ...]` list form is exactly right for forcing groups/email into Grafana's ID token/userinfo (the Authelia Grafana integration flags that Grafana doesn't request claims the normal way). Adjust to the custom_claims form if validate-config complains.
- How should oidc.issuer.pem reach the node? Extend the compose_stack role to render a SOPS-decrypted file (mode 0600), add a dedicated ansible task, or drop it manually? Pick one and wire it into the deploy flow.
- Group taxonomy: OK to standardize on admins / arcane-admins / grafana-admins / grafana-editors? These are referenced by the Arcane OIDC_ROLE_MAPPINGS and the Grafana ROLE_ATTRIBUTE_PATH — confirm names and seed them in users_database.yml.
- Auth strength: start at one_factor everywhere to match TinyAuth's single-factor behavior (chosen here), then raise sensitive hosts to two_factor? Or go two_factor from day one (forces TOTP enrollment before first access)?
- Sessions are in-memory (single node, no Redis) so an authelia restart drops all sessions and forces re-login. Acceptable for the lab, or add a Redis session backend (extra internal network + container)?
- Middleware naming: this keeps the steady-state name `authelia@docker` (apps get relabeled once). If you'd rather preserve the backend-neutral `auth@docker` name long-term, that's a second relabel pass after tinyauth is gone — confirm preference.

---

## Decisions locked (2026-07-05)

1. **Auth strength: `one_factor` for now** — matches TinyAuth's single-factor behavior. `access_control` is already `default_policy: deny` + `*.int.v2e.sh: one_factor`. Raise sensitive hosts (traefik dashboard, arcane) to `two_factor` later, once TOTP is enrolled.
2. **Sessions: in-memory now, Redis later** — see the `REDIS LATER` note in `config/configuration.yml`. OIDC state persists in SQLite; only the browser cookie drops on an Authelia restart.
3. **Group taxonomy confirmed:** `admins` / `arcane-admins` / `grafana-admins` / `grafana-editors`. The admin user in `users_database.yml` holds `admins,arcane-admins,grafana-admins`; add `grafana-editors` to non-admin editor users as needed.
4. **RS256 issuer key rendered from SOPS** — provisioning task below (closes review must-fix #4).

## RS256 issuer-key provisioning (implements decision #4)

`authelia_oidc_issuer_key` (the multiline RS256 PEM) can't be a `.env` value, so the `compose_stack` role renders it to the mounted `config/secrets/oidc.issuer.pem`. Add this to `roles/compose_stack/tasks/main.yml` **after the git-clone task**, gated on the authelia stack. `authelia/config/secrets/` is already gitignored (see `authelia/.gitignore`), so the untracked PEM survives repo pulls.

```yaml
- name: Provision the Authelia OIDC issuer key (RS256 PEM) from SOPS
  when: "'authelia' in compose_stack_stacks"
  block:
    - name: Ensure the Authelia secrets dir exists (0700)
      ansible.builtin.file:
        path: "{{ compose_stack_dir }}/authelia/config/secrets"
        state: directory
        owner: root
        group: root
        mode: "0700"
    - name: Render the OIDC issuer private key (0600, never logged)
      ansible.builtin.copy:
        content: "{{ authelia_oidc_issuer_key }}"
        dest: "{{ compose_stack_dir }}/authelia/config/secrets/oidc.issuer.pem"
        owner: root
        group: root
        mode: "0600"
      no_log: true
```

Generate the key (decision #4): `docker run --rm -v "$PWD:/keys" authelia/authelia:4.39.20 authelia crypto pair rsa generate --bits 4096 --directory /keys`, then put the **private** key PEM into SOPS as `authelia_oidc_issuer_key`.
