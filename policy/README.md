# policy/ — правила conftest (Rego v1)

Пакет `main`, движок OPA 1.x (conftest 0.71.1). Синтаксис — только Rego v1:
`deny contains msg if { ... }`, `warn contains msg if { ... }`. Старое `deny[msg] { ... }`
не парсится (`rego_parse_error: 'if' keyword is required`).

Один набор правил прогоняется по трём входам:

```bash
helm template lc charts/launch-control -f charts/launch-control/values-prod.yaml | conftest test - --policy policy/
kubectl kustomize overlays/production | conftest test - --policy policy/
conftest test terraform/plan.json --policy policy/
```

## Файлы

| Файл | Вход | Правила |
|---|---|---|
| `kubernetes.rego` | манифесты (helm и kustomize) | 5 deny + 7 warn |
| `terraform_plan.rego` | `terraform/plan.json` | 5 warn |

Разделение по входам обеспечено проверками наличия полей: правила манифестов начинаются
с `input.kind != null`, правила плана — с `some rc in input.resource_changes`. У плана нет
`kind`, у манифестов нет `resource_changes`, поэтому чужие правила просто не вычисляются.

## Почему схемная валидация (kubeconform) это пропускает

| Правило | Уровень | Почему kubeconform молчит |
|---|---|---|
| `privileged: true` | deny | поле `securityContext.privileged` — легальный `boolean`, схема не знает, что true опасно |
| `hostPath` в `volumes` | deny | `hostPath.path` — обычная строка; схема не различает emptyDir, PVC и каталог хоста |
| `hostNetwork: true` | deny | легальный `boolean` в PodSpec |
| образ без тега / `:latest` | deny | `image` — произвольная строка, формат тега схемой не ограничен |
| литеральный секрет в `env` | deny | `env[].value` — легальная строка; схема не отличает пароль от `LOG_LEVEL` |
| `runAsNonRoot != true`, `runAsUser == 0` | warn | любые `boolean`/`integer` валидны, `0` — корректное число |
| нет `resources.requests/limits` | warn | в PodSpec все поля контейнера опциональны |
| нет `livenessProbe`/`readinessProbe` | warn | пробы не обязательны по схеме |
| stateful-ресурс в `delete`/`replace` | warn | `plan.json` — не объект Kubernetes, схемы для него нет вообще |
| ingress `0.0.0.0/0` (порт 22) | warn | `cidr_blocks` — список строк, значения схемой не проверяются |
| IAM `Action "*"` / `Resource "*"` | warn | политика лежит строкой JSON внутри `after.policy`, для схемы это непрозрачные данные |

Вывод: схема отвечает на вопрос «это валидный объект Kubernetes 1.29?», а не «это
безопасный объект». Второй вопрос закрывают эти правила.

## deny и warn: почему не всё deny

`helm`-путь (чарт) вычищен в шагах 2–4, `kustomize`-путь (`base/`) — legacy: без
`securityContext`, без `resources`, без проб. Правила 4–5 описывают именно этот осознанный
техдолг, поэтому они `warn`: сделать их `deny` сейчас значит навсегда покрасить
`kubectl kustomize` в красный и приучить игнорировать вывод.

Когда `base/` захарденят, правила 4–5 поднимаются в `deny` одной правкой ключевого слова —
больше ничего менять не нужно. `deny` оставлен только для того, чего не должно быть ни в
одном окружении ни при каких условиях: privileged, hostPath, hostNetwork, `latest`,
литеральные секреты.

## Режимы прогона

| Команда | Поведение |
|---|---|
| `make validate` | conftest без `--fail-on-warn`: `deny` валит, `warn` только печатается |
| `make policy` | то же для policy-шагов |
| `make gate-plan` | `conftest test terraform/plan.json --policy policy/ --fail-on-warn` — единственное место, где warn валит сборку (veto по плану) |

## Текущее состояние (факт прогона)

- helm-рендер: 51 тест, 0 предупреждений, 0 нарушений — чарт проходит и deny, и warn.
- kustomize-рендер: 5 предупреждений (runAsNonRoot, resources.requests/limits, liveness/readiness) — ожидаемый техдолг `base/`.
- `terraform/plan.json`: 5 предупреждений — replace `aws_db_instance.launch_manifest`, delete `aws_db_parameter_group.legacy`, IAM `Action "*"` и `Resource "*"`, SSH cidr `0.0.0.0/0` у `aws_security_group.api`.
- baseline-версия чарта (`git show 5201396:...`): 3 нарушения (privileged, `:latest`, hostPath) — правила ловят исходные дефекты.

## Ограничения (осознанные)

- Проверяются только `spec.template.spec.containers`; `initContainers` и `ephemeralContainers` не покрыты.
- Покрыты workload'ы с `spec.template.spec` (Deployment, StatefulSet, DaemonSet, Job);
  `CronJob` (`spec.jobTemplate.spec.template.spec`) не покрыт.
- IAM разбирается только по `Statement[].Action/Resource`; `NotAction`, `NotResource`, условия — вне покрытия.
- Security group проверяется по `change.after.ingress`; `egress` и `aws_security_group_rule` не проверяются.
- Всё это — кандидаты на расширение правил, в минимум задания не входят.
