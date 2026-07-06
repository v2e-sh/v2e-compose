# v2e-compose — local bootstrap & operations for the Traefik + TLS + auth stack.
# LOCAL/standalone front door only. The automated lab path is
# `terraform apply` -> Ansible -> ANS-3 (docker_compose_v2); make is not involved there.

# NOTE ON AUTH: the auth layer (Authelia SSO) is NOT in this standalone path. It
# needs SOPS-rendered crypto material — an RS256 issuer key, the admin argon2id hash,
# pbkdf2 client-secret hashes, and a fully rendered configuration.yml — all produced
# by the Ansible role (roles/compose_stack), not by env-injection. `make` deploys the
# unauthenticated front door (traefik + whoami); the lab deploys the full authelia
# stack via `terraform apply -> Ansible`.
SHELL    := /bin/bash
COMPOSE  := docker compose
ENVFILE  := .env
SECRETS  := secrets.sops.yaml
TRAEFIK  := -f traefik/compose.yml
WHOAMI   := -f whoami/compose.yml

.DEFAULT_GOAL := help
.PHONY: help bootstrap up prod down logs validate

help:
	@echo "targets: bootstrap | up | prod | down | logs | validate"

bootstrap:
	@docker network inspect frontend >/dev/null 2>&1 || docker network create frontend
	@[ -f $(ENVFILE) ] || { cp .env.example $(ENVFILE); echo "created $(ENVFILE) — edit DOMAIN / ACME_EMAIL"; }
	@mkdir -p traefik/data/certs
	@if [ ! -f $(SECRETS) ]; then \
		if [ -z "$$SOPS_AGE_KEY_FILE" ] && [ ! -f "$$HOME/.config/sops/age/keys.txt" ]; then \
			echo "No age key found. Run age-keygen first (see README)."; exit 1; \
		fi; \
		sops --encrypt secrets.sops.yaml.example > $(SECRETS); \
		echo "created $(SECRETS) — set CF_DNS_API_TOKEN"; \
		sops $(SECRETS); \
	fi
	@echo "bootstrap done. Next: edit .env, then 'make up'"

up:
	sops exec-env $(SECRETS) '$(COMPOSE) --env-file $(ENVFILE) $(TRAEFIK) up -d'
	$(COMPOSE) --env-file $(ENVFILE) $(WHOAMI) up -d

prod:
	sops exec-env $(SECRETS) 'CERT_RESOLVER=production $(COMPOSE) --env-file $(ENVFILE) $(TRAEFIK) up -d'
	CERT_RESOLVER=production $(COMPOSE) --env-file $(ENVFILE) $(WHOAMI) up -d

down:
	-$(COMPOSE) $(WHOAMI) down
	-CF_DNS_API_TOKEN=unused $(COMPOSE) $(TRAEFIK) down

logs:
	CF_DNS_API_TOKEN=unused $(COMPOSE) $(TRAEFIK) logs -f traefik

validate:
	@DOMAIN=example.com ACME_EMAIL=a@b.c CERT_RESOLVER=staging CF_DNS_API_TOKEN=dummy \
		$(COMPOSE) $(TRAEFIK) config >/dev/null && echo "traefik/compose.yml OK"
	@DOMAIN=example.com CERT_RESOLVER=staging \
		$(COMPOSE) $(WHOAMI) config >/dev/null && echo "whoami/compose.yml OK"
