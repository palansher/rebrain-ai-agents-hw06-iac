# Локальный pipeline стенда iac-lab. Кластер не нужен, ничего не применяется.
#   make validate   - helm lint/template + kubeconform, kustomize + kubeconform, policy, секреты
#                     (conftest без --fail-on-warn: deny валит, warn только печатается)
#   make policy     - только conftest по policy/
#   make gate-plan  - conftest по terraform/plan.json с --fail-on-warn (veto-режим)
#   make ci         - validate, затем gate-plan
#   make score      - табло на 8 слоёв (./scripts/score.sh, не менять)
SHELL := /bin/bash

.DEFAULT_GOAL := validate
.PHONY: help validate policy gate-plan ci score

help: ## список целей
	@printf 'make validate     полный pipeline; conftest без --fail-on-warn (deny валит, warn печатается)\n'
	@printf 'make policy       только conftest по policy/ (без --fail-on-warn)\n'
	@printf 'make gate-plan    conftest terraform/plan.json с --fail-on-warn;\n'
	@printf '                  на текущем плане ОЖИДАЕМО падает (warn-правила = veto)\n'
	@printf 'make ci           validate, затем gate-plan\n'
	@printf 'make score        табло на 8 слоёв (./scripts/score.sh)\n'
	@printf 'Пустой policy/ валит validate; временно: ALLOW_EMPTY_POLICY=1 make validate\n'
	@printf 'K8S_VERSION по умолчанию задан в scripts/validate.sh; переопределение:\n'
	@printf '  make validate K8S_VERSION=1.30.0\n'

validate: ## полный validation pipeline
	@K8S_VERSION='$(K8S_VERSION)' ALLOW_EMPTY_POLICY='$(ALLOW_EMPTY_POLICY)' ./scripts/validate.sh all

policy: ## только контрактные тесты
	@K8S_VERSION='$(K8S_VERSION)' ALLOW_EMPTY_POLICY='$(ALLOW_EMPTY_POLICY)' ./scripts/validate.sh policy

gate-plan: ## conftest plan.json с --fail-on-warn (ожидаемо падает до шага 7)
	@K8S_VERSION='$(K8S_VERSION)' ALLOW_EMPTY_POLICY='$(ALLOW_EMPTY_POLICY)' ./scripts/validate.sh gate-plan

ci: validate gate-plan ## validate, затем gate-plan

score: ## табло преподавателя
	@./scripts/score.sh
