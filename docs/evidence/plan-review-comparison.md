# Сверка: ответ агента (P8) ↔ независимая проверка `jq`

- Ответ агента: `docs/agent/plan-review.md`
- Транскрипт (промпт + ответ): `docs/agent/transcripts/p8-session.md`
- Независимая проверка: `docs/evidence/plan-jq.txt`
- Источник данных: `terraform/plan.json`

## Утверждения агента и проверка

| # | Утверждение агента | Проверка `jq` | Итог |
|---|---|---|---|
| 1 | 9 `resource_change`, из них 3 с удалением | `resource_changes` = 9; с `delete` = 3 | подтверждено |
| 2 | `aws_db_instance.launch_manifest` — replace | actions = `delete,create` | подтверждено |
| 3 | RDS: `engine_version 15.7→16.3`, `skip_final_snapshot false→true`, `deletion_protection true→false`, `backup_retention_period 7→0` | все 4 поля совпадают в before/after | подтверждено |
| 4 | `aws_db_parameter_group.legacy` — delete, `name: legacy-pg14` | actions = `delete`, before.name = `legacy-pg14` | подтверждено |
| 5 | `aws_ecs_task_definition.api` — replace, `revision 41→42` | actions = `create,delete`, before.revision = 41, after.revision = 42 | подтверждено |
| 6 | IAM: было `s3:GetObject/PutObject` на `launch-artifacts/*`, стало `Action "*"` / `Resource "*"` | строки policy before/after совпадают дословно | подтверждено |
| 7 | SG: SSH `10.0.0.0/8` → `0.0.0.0/0` | before.ingress cidr = `10.0.0.0/8`, after = `0.0.0.0/0`, порт 22 | подтверждено |
| 8 | `aws_ecs_service.api`: `desired_count 2→3` | before 2, after 3, других полей в change нет | подтверждено |
| 9 | `aws_ssm_parameter.app_env`: `staging→production` | before/after совпадают | подтверждено |
| 10 | `aws_cloudwatch_log_group.api` — create, retention 30 | actions = `create`, after.retention_in_days = 30 | подтверждено |
| 11 | `aws_s3_bucket.artifacts` — no-op | actions = `no-op` | подтверждено |
| 12 | План — выжимка: нет `planned_values`, `prior_state`, `configuration`, `after_unknown` и др. | верхнеуровневые ключи: только `format_version`, `resource_changes`, `terraform_version`; ключи `change`: только `actions`, `before`, `after` | подтверждено |
| 13 | В плане нет версии провайдера | `has("provider_version")` = false у всех resource_change | подтверждено |
| 14 | Поля `engine`, `instance_class`, `multi_az`, `storage_encrypted` и др. в плане отсутствуют | в `change` только 4 поля RDS, перечисленных в п.3 | подтверждено |

## Чего агент не сказал (пропуски)

Проверено покрытие всех 9 адресов: каждый упомянут в ответе хотя бы дважды (таблица + выводы).
Содержательных пропусков не выявлено.

## Что агент придумал (галлюцинации)

Не выявлено: все цитаты before/after сверены с `plan.json`. Отдельно отмечено, что агент **не** утверждает
наличие полей, которых в плане нет (наоборот, явно перечисляет отсутствующие), и делает оговорки
(«провайдер… версия не указана», «СУБД не подтверждена», «в плане связей не видно»).

## Что это значит для README

- Пункт «что агент нашёл / пропустил / придумал»: нашёл — всё существенное; пропустил — ничего
  содержательного; придумал — ничего.
- Главная ценность ответа — не таблица, а **явные ограничения плана** (п.12-14): он показывает,
  что по этой выжимке нельзя подтвердить drift, порядок операций и unknown-значения.
- Вывод для пайплайна: ревью агентом не заменяет `jq` и `make gate-plan`; оно добавляет объяснение,
  но истина — в данных и правилах.
