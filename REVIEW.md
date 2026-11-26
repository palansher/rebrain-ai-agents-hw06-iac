# REVIEW.md — чеклист человека перед одобрением IaC-изменения

Артефакт: Helm-чарт `charts/launch-control`, Kustomize `base/ + overlays/production`,
сохранённый план `terraform/plan.json`. Целевая версия Kubernetes — **1.29.0**.

Автор чеклиста — человек (ревьюер). Агент вносил правки в код и правила; чеклист фиксирует,
что именно человек обязан проверить перед `apply`, и не заменяется зелёным `make validate`.

## Как пользоваться

1. Прогнать автоматику: `make validate` (ожидается 0) и `make gate-plan` (ожидается ≠0).
2. Пройти 15 пунктов ниже; для каждого записать результат и ссылку на вывод.
3. Заполнить блок «Решение». Без подписи человека `apply` запрещён.

Подготовка:

```bash
cd /home/vp/my/rebrain/hw06/iac-lab
export K8S_VERSION=1.29.0
export R=/tmp/render.yaml
helm template lc charts/launch-control -f charts/launch-control/values-prod.yaml > "$R"
```

## Обзор

| № | Проверка | Блокирует |
|---|---|---|
| 1 | Схема и API соответствуют Kubernetes 1.29.0 (Helm-рендер) | да |
| 2 | Схема и API соответствуют Kubernetes 1.29.0 (Kustomize-рендер) | да |
| 3 | `helm lint --strict` без предупреждений | да |
| 4 | Тег образа зафиксирован, нет `latest` | да |
| 5 | Нет `privileged`, `hostPath`, `hostNetwork` | да |
| 6 | Нет секретов в values и в `env` | да |
| 7 | Секретов нет в истории git публикуемой ветки | да |
| 8 | Секреты приходят из существующего Secret | да |
| 9 | Non-root: `runAsNonRoot`, UID/GID, seccomp | нет (warn) |
| 10 | `resources` requests/limits и обе пробы | нет (warn) |
| 11 | Ingress ссылается на существующий Service | нет, но требует решения |
| 12 | PDB `policy/v1` и осмысленный `minAvailable` | да |
| 13 | В плане нет delete/replace stateful без одобрения | да |
| 14 | Нет расширения прав: IAM `"*"`, SG `0.0.0.0/0` | да |
| 15 | План снят с проверяемой ревизии; есть approve, окно, rollback; нет auto-apply | да |

## Команды и критерии

### 1. Схема и API соответствуют Kubernetes 1.29.0 (Helm-рендер)
```bash
kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" "$R"
```
Провал: exit ≠ 0, `Invalid`/`Errors` > 0.

### 2. Схема и API соответствуют Kubernetes 1.29.0 (Kustomize-рендер)
```bash
kubectl kustomize overlays/production | kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
```
Провал: exit ≠ 0.

### 3. `helm lint --strict` без предупреждений
```bash
helm lint --strict charts/launch-control -f charts/launch-control/values-prod.yaml
```
Провал: любой `[WARNING]`/`[ERROR]`; `[INFO]` про icon допустим.

### 4. Тег образа зафиксирован, нет `latest`
```bash
yq -r 'select(.kind=="Deployment") | .spec.template.spec.containers[].image' "$R" | grep -E ':latest$|^[^:]+$' || echo 'OK: все образы с тегом'
```
Провал: есть вывод (пусто = ок). Digest `@sha256:` считается закреплением.

### 5. Нет `privileged`, `hostPath`, `hostNetwork`
```bash
conftest test "$R" --policy policy/
```
Провал: exit ≠ 0 или строки `FAIL` с `privileged`/`hostPath`/`hostNetwork`. (grep по рендеру ненадёжен: Helm сохраняет комментарии шаблонов, и слово hostPath встречается в комментарии.)

### 6. Нет секретов в values и в `env`
```bash
grep -rEn '(adminToken|databasePassword|password):[[:space:]]*[^[:space:]]' charts/launch-control/values*.yaml || echo 'OK: секретов в values нет'
```
Провал: счётчик > 0 или `failures` > 0.

### 7. Секретов нет в истории git публикуемой ветки
```bash
git log -p --all -- 'charts/launch-control/values*.yaml' | grep -cE '(adminToken|databasePassword):[[:space:]]*"'
```
Провал: > 0. До публикации из orphan-ветки локально ожидаемо > 0; в публикуемой ветке обязано быть 0.

### 8. Секреты приходят из существующего Secret
```bash
yq '.existingSecret' charts/launch-control/values.yaml
yq -r 'select(.kind=="Deployment") | .spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef != null) | .name' "$R"
grep -rl 'kind: Secret' charts/ || echo 'OK: Secret не создаётся чартом'
```
Провал: пустой `existingSecret`, нет `secretKeyRef` или чарт создаёт Secret со значениями.

### 9. Non-root: `runAsNonRoot`, UID/GID, seccomp
```bash
yq -r 'select(.kind=="Deployment") | .spec.template.spec.securityContext' "$R"
```
Провал: для `base/` отсутствует — осознанный техдолг, фиксируется в README.

### 10. `resources` requests/limits и обе пробы
```bash
yq -r 'select(.kind=="Deployment") | .spec.template.spec.containers[0]' "$R" | grep -nE 'resources:|limits:|requests:|livenessProbe:|readinessProbe:'
```
Провал: для `base/` отсутствует — техдолг.

### 11. Ingress ссылается на существующий Service
```bash
kube-score score "$R" 2>&1 | grep -c 'Ingress targets Service'
```
Провал: `1` = Service в чарте нет. Допустимо только с явным решением: добавить Service или записать техдолг в README.

### 12. PDB `policy/v1` и осмысленный `minAvailable`
```bash
kubectl kustomize overlays/production | yq -r 'select(.kind=="PodDisruptionBudget") | .apiVersion + " minAvailable=" + (.spec.minAvailable|tostring)'
```
Провал: не `policy/v1`, либо PDB отсутствует там, где ожидается.

### 13. В плане нет delete/replace stateful без одобрения
```bash
make gate-plan; echo "gate exit=$?"
jq -r '.resource_changes[] | select(.change.actions | index("delete")) | .address' terraform/plan.json
```
Провал: gate вернул 0 или список не разобран. Ненулевой exit — блокировка сработала.

### 14. Нет расширения прав: IAM `"*"`, SG `0.0.0.0/0`
```bash
jq -r '.resource_changes[] | select(.address=="aws_iam_policy.api" or .address=="aws_security_group.api") | .address + " -> " + (.change.after|tostring)' terraform/plan.json
```
Провал: `Action`/`Resource` `"*"` или `0.0.0.0/0` без письменного обоснования и компенсирующих мер.

### 15. План снят с проверяемой ревизии; есть approve, окно, rollback; нет auto-apply
```bash
grep -nE 'deletion_protection|backup_retention_period|cidr_blocks|Action' terraform/main.tf
```
Провал: `main.tf` и план расходятся без объяснения; в схеме есть путь к `apply` без человека; не определены окно, ответственный и план отката.

## Чего чеклист не проверяет

- реальное поведение приложения (нужен запуск образа и smoke-тесты в кластере);
- drift относительно живого облака (`prior_state` в плане отсутствует);
- порядок операций и `create_before_destroy` (в плане нет `configuration`);
- unknown-значения после apply (`after_unknown` отсутствует);
- стоимость изменения.

Это отдельные задачи стадии «после approve». Их отсутствие означает не «всё хорошо», а «не проверялось».

## Решение

| Поле | Значение |
|---|---|
| Ревизия / коммит | |
| `terraform/plan.json` sha256 | |
| `make validate` | exit __ |
| `make gate-plan` | exit __ (≠0 — блокировка сработала) |
| Открытые пункты (№) | |
| Решение | ☐ одобрено ☐ отклонено ☐ на доработку |
| Окно / rollback / ответственный | |
| Ревьюер, дата | |
