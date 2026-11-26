#!/usr/bin/env bash
# Локальный validation pipeline стенда iac-lab (не табло scripts/score.sh).
#   ./scripts/validate.sh          # все слои
#   ./scripts/validate.sh policy   # только conftest по policy/
# Обычно запускается через make: make validate / make policy.
# Останавливается на первой ошибке и печатает, какой слой упал и с каким кодом.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CHART="charts/launch-control"
VALUES_PROD="$CHART/values-prod.yaml"
OVERLAY="overlays/production"
POLICY_DIR="policy"
PLAN_JSON="terraform/plan.json"

# Единственное место, где задана версия Kubernetes. Переопределяется окружением:
#   K8S_VERSION=1.30.0 make validate
K8S_VERSION="${K8S_VERSION:-1.29.0}"

MODE="${1:-all}"
TOTAL_ALL=6
STEP=0

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

HELM_RENDER="$WORK_DIR/helm-render.yaml"
KUSTOMIZE_RENDER="$WORK_DIR/kustomize-render.yaml"

step() {
	if [ "$MODE" = "all" ]; then
		STEP=$((STEP + 1))
		printf '\n=== [%d/%d] %s ===\n' "$STEP" "$TOTAL_ALL" "$1"
	else
		printf '\n=== [%s] %s ===\n' "$MODE" "$1"
	fi
}

ok() { printf '  OK: %s\n' "$1"; }
skip() { printf '  SKIP: %s\n' "$1"; }

need() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'FAIL: не найден инструмент "%s" — установите его вручную, скрипт ничего не ставит.\n' "$1" >&2
		exit 127
	fi
}

# check "<имя слоя>" <команда...> — единая точка отчёта о падении
check() {
	local layer="$1"
	shift
	local rc=0
	"$@" || rc=$?
	if [ "$rc" -ne 0 ]; then
		printf '\nFAIL: слой "%s" упал с кодом %d — пайплайн остановлен.\n' "$layer" "$rc" >&2
		exit "$rc"
	fi
	ok "$layer"
}

render_helm() { helm template lc "$CHART" --values "$VALUES_PROD" >"$HELM_RENDER"; }
render_kustomize() { kubectl kustomize "$OVERLAY" >"$KUSTOMIZE_RENDER"; }

have_policies() { ls "$POLICY_DIR"/*.rego >/dev/null 2>&1; }

# Пустой policy/ — это не "нечего проверять", а непроверенный слой:
# по умолчанию FAIL. SKIP только при ALLOW_EMPTY_POLICY=1 (временный режим до шага 7).
policies_ready() {
	have_policies && return 0
	if [ "${ALLOW_EMPTY_POLICY:-0}" = "1" ]; then
		skip "policy/*.rego не найдены: policy-слой не проверен (ALLOW_EMPTY_POLICY=1)"
		return 1
	fi
	printf '\nFAIL: policy/*.rego не найдены: policy-слой не проверен.\n' >&2
	exit 1
}

check_secrets() {
	local pattern count=0 file hits
	# тот же шаблон, что в scripts/score.sh: имя ключа + непустое значение
	pattern="(adminToken|databasePassword|password):[[:space:]]*[\"']?[^\"' ]"
	shopt -s nullglob
	for file in "$CHART"/values*.yaml; do
		hits="$(grep -Ec -- "$pattern" "$file" || true)"
		count=$((count + hits))
	done
	if [ "$count" -ne 0 ]; then
		printf '  FAIL: в values найдено %d строк с секретами\n' "$count" >&2
		return 1
	fi
}

step_helm_lint() {
	step "helm lint --strict"
	need helm
	check "helm lint --strict ($VALUES_PROD)" \
		helm lint --strict "$CHART" --values "$VALUES_PROD"
}

step_helm_kubeconform() {
	step "helm template -> kubeconform (Kubernetes $K8S_VERSION)"
	need helm
	need kubeconform
	check "helm template (рендер)" render_helm
	check "kubeconform (helm, $K8S_VERSION)" \
		kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" "$HELM_RENDER"
}

step_kustomize_kubeconform() {
	step "kubectl kustomize -> kubeconform (Kubernetes $K8S_VERSION)"
	need kubectl
	need kubeconform
	check "kustomize build (рендер)" render_kustomize
	check "kubeconform (kustomize, $K8S_VERSION)" \
		kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" "$KUSTOMIZE_RENDER"
}

step_policy_manifests() {
	step "conftest: отрендеренные манифесты"
	policies_ready || return 0
	need conftest
	[ -s "$HELM_RENDER" ] || render_helm
	[ -s "$KUSTOMIZE_RENDER" ] || render_kustomize
	# режим validate: deny валит сборку, warn только печатается
	check "conftest (helm-манифесты)" \
		conftest test "$HELM_RENDER" --policy "$POLICY_DIR"
	check "conftest (kustomize-манифесты)" \
		conftest test "$KUSTOMIZE_RENDER" --policy "$POLICY_DIR"
}

step_policy_plan() {
	step "conftest: terraform/plan.json"
	policies_ready || return 0
	need conftest
	if [ ! -f "$PLAN_JSON" ]; then
		printf 'FAIL: нет файла %s — снять план нечем (нет кредов).\n' "$PLAN_JSON" >&2
		exit 1
	fi
	check "conftest (terraform plan)" \
		conftest test "$PLAN_JSON" --policy "$POLICY_DIR"
}

# Единственное место, где warn валит сборку.
step_gate_plan() {
	step "gate: conftest terraform/plan.json --fail-on-warn"
	# gate не должен проходить при пустой policy/ даже с ALLOW_EMPTY_POLICY=1
	have_policies || {
		printf '\nFAIL: policy/*.rego не найдены — gate без правил не имеет смысла.\n' >&2
		exit 1
	}
	need conftest
	if [ ! -f "$PLAN_JSON" ]; then
		printf 'FAIL: нет файла %s — снять план нечем (нет кредов).\n' "$PLAN_JSON" >&2
		exit 1
	fi
	check "conftest (terraform plan, --fail-on-warn)" \
		conftest test "$PLAN_JSON" --policy "$POLICY_DIR" --fail-on-warn
}

step_secrets() {
	step "секреты в values"
	check "нет секретов в values" check_secrets
}

case "$MODE" in
all)
	step_helm_lint
	step_helm_kubeconform
	step_kustomize_kubeconform
	step_policy_manifests
	step_policy_plan
	step_secrets
	printf '\nPASS: все слои пройдены (Kubernetes %s).\n' "$K8S_VERSION"
	;;
policy)
	step_policy_manifests
	step_policy_plan
	printf '\nPASS: policy-слои пройдены.\n'
	;;
gate-plan)
	step_gate_plan
	printf '\nPASS: gate-plan пройден.\n'
	;;
*)
	printf 'usage: %s [all|policy|gate-plan]\n' "${BASH_SOURCE[0]}" >&2
	exit 2
	;;
esac
