# Authelia config

The **authoritative** Authelia `configuration.yml` template lives in the Ansible role, not
here, to avoid two copies drifting apart:

    v2e-ansible/roles/compose_stack/templates/authelia-configuration.yml.j2

At deploy time the `compose_stack` role renders it (with the RS256 issuer key + client-secret
hashes inlined from SOPS) to `/opt/authelia-secrets/configuration.yml` — **outside** the
compose tree, so the Arcane container (which bind-mounts the tree) can't read the IdP key —
and the `authelia` stack mounts it from that absolute path.

`users_database.yml.example` here is a reference for the admin/groups shape; the real file is
rendered the same way to `/opt/authelia-secrets/users_database.yml`.
