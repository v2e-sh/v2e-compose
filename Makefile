# v2e-compose — local bootstrap & operations for the Traefik + TLS + auth stack.
# LOCAL/standalone front door only. The automated lab path is
# `terraform apply` -> Ansible -> ANS-3 (docker_compose_v2); make is not involved there.

SHELL    := /bin/bash
COMPOSE  := docker compose
ENVFILE  := .env
SECRETS  := secrets.sops.yaml
TRAEFIK  := -f traefik/compose.yml
TINYAUTH := -f tinyauth/compose.yml
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
		echo "created $(SECRETS) — set CF_DNS_API_TOKEN, TINYAUTH_SECRET (openssl rand -hex 16),"; \
		echo "  and TINYAUTH_AUTH_USERS (docker run --rm -it ghcr.io/steveiliop56/tinyauth:v5.0.7 user create)"; \
		sops $(SECRETS); \
	fi
	@echo "bootstrap done. Next: edit .env, then 'make up'"

up:
	sops exec-env $(SECRETS) '$(COMPOSE) --env-file $(ENVFILE) $(TRAEFIK) up -d'
	sops exec-env $(SECRETS) '$(COMPOSE) --env-file $(ENVFILE) $(TINYAUTH) up -d'
	$(COMPOSE) --env-file $(ENVFILE) $(WHOAMI) up -d

prod:
	sops exec-env $(SECRETS) 'CERT_RESOLVER=production $(COMPOSE) --env-file $(ENVFILE) $(TRAEFIK) up -d'
	sops exec-env $(SECRETS) '$(COMPOSE) --env-file $(ENVFILE) $(TINYAUTH) up -d'
	CERT_RESOLVER=production $(COMPOSE) --env-file $(ENVFILE) $(WHOAMI) up -d

down:
	-$(COMPOSE) $(WHOAMI) down
	-TINYAUTH_SECRET=unused TINYAUTH_AUTH_USERS=unused $(COMPOSE) $(TINYAUTH) down
	-CF_DNS_API_TOKEN=unused $(COMPOSE) $(TRAEFIK) down

logs:
	CF_DNS_API_TOKEN=unused $(COMPOSE) $(TRAEFIK) logs -f traefik

validate:
	@DOMAIN=example.com ACME_EMAIL=a@b.c CERT_RESOLVER=staging CF_DNS_API_TOKEN=dummy \
		$(COMPOSE) $(TRAEFIK) config >/dev/null && echo "traefik/compose.yml OK"
	@DOMAIN=example.com TINYAUTH_SECRET=dummy TINYAUTH_AUTH_USERS=dummy \
		$(COMPOSE) $(TINYAUTH) config >/dev/null && echo "tinyauth/compose.yml OK"
	@DOMAIN=example.com CERT_RESOLVER=staging \
		$(COMPOSE) $(WHOAMI) config >/dev/null && echo "whoami/compose.yml OK"
