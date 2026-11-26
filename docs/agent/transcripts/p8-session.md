# P8 — ревью `terraform/plan.json` (транскрипт сессии)

- session: `ses_de931fd51ffes6S8OFlmCzdNoF`
- model: `opencode-go/deepseek-v4.1-flash` (variant: default)
- date: 2026-11-26
- source: `opencode session export <session-id>` (полный JSON не коммитится: содержит синтетические секреты из шагов 1-4)

> Промпт и ответ приведены дословно. Файл `docs/agent/plan-review.md` совпадает с ответом;
> различия — только преамбула агента (процитирована ниже).

## Промпт

```text
Контекст: terraform/plan.json — сохранённый вывод terraform show -json tfplan (terraform 1.9.5,
провайдер aws ~>5.0). Облака нет, apply запрещён. Ничего не меняй в файлах.

Задача: разбери план и выдай таблицу по каждому resource_change:
адрес | actions | что меняется (before → after по значимым полям) | риск | blast radius | рекомендация.
Отдельно ответь:
1) какие ресурсы удаляются или пересоздаются (replace = delete+create);
2) где расширяются права (IAM) и сетевая доступность (security group);
3) какие последствия у replace aws_db_instance (данные, бэкапы, downtime);
4) что в плане безобидно и почему;
5) чего в плане НЕ хватает для безопасного применения.

Требования:
- не выдумывай поля: цитируй before/after из JSON;
- если чего-то не видно в plan.json — так и скажи (нет provider-specific деталей и т.п.);
- в конце перечисли 3-5 вопросов, которые человек должен задать перед approve.

Запиши весь свой ответ дословно (таблицу и все пункты, без сокращений) в файл
docs/agent/plan-review.md. Другие файлы не меняй. Если файл уже есть - перезапиши.
```

## Преамбула агента

Ответ записан в `docs/agent/plan-review.md` (84 строки), других файлов не менял. Дальше — дословно то, что в файле.

## Ответ ассистента

# Ревью `terraform/plan.json` — Launch Control

Источник: сохранённый `terraform show -json tfplan`, `terraform_version: 1.9.5`, `format_version: 1.2`, провайдер `registry.terraform.io/hashicorp/aws` (версия провайдера в плане не указана). Кластера и облака нет, `apply` не выполнялся и не должен выполняться по этому плану без ответов на вопросы в конце.

Итог: **9 resource_change, из них 3 с удалением** (`aws_db_instance.launch_manifest` — replace, `aws_ecs_task_definition.api` — replace, `aws_db_parameter_group.legacy` — delete). Два изменения критичны (IAM `*`/`*` и замена прод-БД с отключёнными бэкапами), одно — прямой выход SSH в интернет. Применять в текущем виде нельзя.

## Важно: полнота плана

В файле есть только три ключа верхнего уровня: `format_version`, `resource_changes`, `terraform_version`. Отсутствуют `planned_values`, `prior_state`, `configuration`, `output_changes`, `variables`, `checks`, `timestamp`, `applyable`, `complete`, `errored`, `relevant_attributes`. У каждого `resource_change` есть только `address`, `type`, `name`, `provider_name`, `change`, а в `change` — только `actions`, `before`, `after`; нет `after_unknown`, `after_sensitive`, `deposed`, `index`, `module_address`.

Следствия, которые надо учитывать при чтении таблицы:

- это **выжимка диффа, а не полный вывод** `terraform show -json`: видны только изменённые поля, остальные атрибуты ресурсов в плане отсутствуют;
- нельзя подтвердить, что в плане нет других изменений, и нельзя проверить drift (`prior_state` нет);
- нельзя увидеть значения, известные только после apply (нет `after_unknown`), — а для `aws_db_instance` такие поля обычно есть (endpoint, идентификатор);
- нельзя проверить порядок операций (`create_before_destroy`, `depends_on`) — в `configuration` этого нет;
- окружение (workspace, аккаунт, регион, теги) в плане не указано. По `aws_ssm_parameter.app_env` значение меняется `staging → production`, то есть план метит **прод-конфигурацию**, — дальше исхожу из этого.

## Таблица по каждому resource_change

| Адрес | actions | Что меняется (before → after) | Риск | Blast radius | Рекомендация |
|---|---|---|---|---|---|
| `aws_db_instance.launch_manifest` | `delete`/`create` (replace) | `engine_version` `"15.7"` → `"16.3"`; `skip_final_snapshot` `false` → `true`; `deletion_protection` `true` → `false`; `backup_retention_period` `7` → `0` | **Critical** | Вся прод-БД: простой на время replace + безвозвратная потеря данных | Не применять. Вернуть `deletion_protection: true`, `skip_final_snapshot: false`, `backup_retention_period ≥ 7`; мажорный апгрейд 15→16 делать отдельным окном, через снапшот/реплику и тест приложения |
| `aws_db_parameter_group.legacy` | `delete` | `name`: `"legacy-pg14"` → `null` (ресурс уничтожается) | **High** | Параметры БД; если группа используется инстансом — ошибка apply или падение производительности/поведения | Проверить, что группа не привязана ни к одному инстансу (в плане связей не видно); экспортировать параметры; удалять только после БД |
| `aws_ecs_task_definition.api` | `create`/`delete` (replace) | `revision`: `41` → `42` | Low (сам по себе) / Medium (в связке) | Новая immutable-ревизия; работающий сервис сам на неё не переключится | Убедиться, что `aws_ecs_service.api` получит `task_definition` с новой ревизией: в диффе сервиса есть только `desired_count` |
| `aws_iam_policy.api` | `update` | `policy`: `{"Statement":[{"Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::launch-artifacts/*"]}]}` → `{"Statement":[{"Action":["*"],"Resource":["*"]}]}` | **Critical** | Весь AWS-аккаунт: полные права на любые действия и ресурсы у всех, к кому политика прикреплена | Отклонить. Вернуть минимальные `s3:GetObject`/`s3:PutObject` на `launch-artifacts/*`; `Action`/`Resource` `*` — только для отдельной break-glass роли с MFA/условиями |
| `aws_security_group.api` | `update` | `ingress`: `{from_port:22, to_port:22, cidr_blocks:["10.0.0.0/8"]}` → `{from_port:22, to_port:22, cidr_blocks:["0.0.0.0/0"]}` | **Critical** | SSH-порт всего интернета: брутфорс, эксплуатация уязвимостей, точка входа для латерального движения | Отклонить. Оставить `10.0.0.0/8` либо bastion/VPN/SSM Session Manager; egress и IPv6 в плане не видны — проверить отдельно |
| `aws_cloudwatch_log_group.api` | `create` | `name`: `"/ecs/launch-control"`, `retention_in_days`: `30` | Info / Low | Новый лог-груп; появляется стоимость хранения и срок ретенции 30 дней | Приемлемо, можно применять отдельно от остального |
| `aws_s3_bucket.artifacts` | `no-op` | `bucket`: `"launch-artifacts"` → `"launch-artifacts"` | Нет | Нет: ресурс не меняется | Ничего делать не нужно, apply для него no-op |
| `aws_ecs_service.api` | `update` | `desired_count`: `2` → `3` | Low (деньги/ёмкость) | +1 задача ECS: нагрузка на кластер, стоимость, квоты | Приемлемо при согласованной ёмкости; проверить квоты и capacity provider (в плане их нет) |
| `aws_ssm_parameter.app_env` | `update` | `value`: `"staging"` → `"production"` | Medium | Все потребители параметра переключатся на прод-значение | Применять синхронно с деплоем; убедиться, что прод-конфиг валиден и не содержит секретов в открытом виде |

## 1) Что удаляется или пересоздаётся

- **`aws_db_instance.launch_manifest` — replace (`delete`/`create`).** По умолчанию Terraform для `aws_db_instance` не использует `create_before_destroy` (а `configuration` в плане нет, подтвердить нельзя), то есть ожидаемая последовательность — удалить старую БД, затем создать новую. Это не «обновление версии», а новая БД.
- **`aws_db_parameter_group.legacy` — `delete`.** Удаляется группа параметров `legacy-pg14` (`after: null`).
- **`aws_ecs_task_definition.api` — replace (`create`/`delete`).** Для ECS это штатное поведение: `revision` `41 → 42`, старая ревизия дерегистрируется после создания новой. Данные не теряются, роль задачи меняется только если в новой ревизии другой definition (сам definition в плане не виден).
- Чистых `delete` без создания — один: `aws_db_parameter_group.legacy`.
- `aws_s3_bucket.artifacts` — `no-op`, не удаляется и не пересоздаётся, хотя имя ресурса и содержит «artifacts».

## 2) Где расширяются права и сетевая доступность

- **IAM (`aws_iam_policy.api`)**: политика из точечной (`s3:GetObject`, `s3:PutObject` на `arn:aws:s3:::launch-artifacts/*`) превращается в `Action: ["*"]`, `Resource: ["*"]`. Это административный уровень в аккаунте: чтение секретов, изменение IAM, удаление данных. К чему именно прикреплена политика — в плане нет (`aws_iam_policy_attachment` / `aws_iam_role_policy_attachment` отсутствуют), поэтому оценить фактический круг субъектов нельзя; худший случай — все роли, к которым она прикреплена.
- **Сеть (`aws_security_group.api`)**: SSH (`from_port`/`to_port` 22) расширяется с корпоративной сети `10.0.0.0/8` до `0.0.0.0/0`, то есть до всего интернета. `egress`, `ipv6_cidr_blocks`, `prefix_list_ids`, `security_groups` и идентификатор SG в плане не видны — проверить отдельно.
- Косвенно: `aws_ssm_parameter.app_env` `staging → production` меняет конфигурацию приложения на прод-значение — это не «права», но это переключение среды.

## 3) Последствия replace `aws_db_instance`

По видимым в плане полям:

1. **Данные.** `skip_final_snapshot: false → true` — при удалении старого инстанса финальный снапшот **не создаётся**. `backup_retention_period: 7 → 0` — автоматические бэкапы и point-in-time recovery **отключаются**. Вместе это значит: в момент replace старые данные уничтожаются без штатной страховки. Восстановление возможно только если есть внешние снапшоты/реплика — в плане их нет, и подтвердить нечем.
2. **Downtime.** Удаление и создание нового инстанса — это простой от нескольких минут до десятков минут (создание, инициализация, DNS). `apply` неатомарен: при ошибке на этапе создания БД останется без базы. Таблица маршрутизации/endpoint в плане не видны, но при replace меняются адрес и порт подключения — приложение должно переподключиться.
3. **Версия.** `engine_version: "15.7" → "16.3"` — это мажорный переход. Поле `engine` в плане отсутствует, поэтому СУБД не подтверждена (имя удаляемой группы `legacy-pg14` намекает на PostgreSQL, но это догадка). Для major upgrade нужны проверка расширений, `pg_upgrade`/dump-restore, тест приложения на новой мажорной версии.
4. **Защита.** `deletion_protection: true → false` снимает защиту от случайного удаления — apply проходит «насквозь», в том числе в будущем.
5. **Чего не видно:** `instance_class`, `multi_az`, `storage_encrypted`, `kms_key_id`, `identifier`, `db_name`, `address`/`endpoint`, `parameter_group_name`, `final_snapshot_identifier`, `apply_immediately`, `maintenance_window` — в плане этих полей нет. Нельзя утверждать ни что БД Multi-AZ, ни что шифрование включено, ни что параметры берутся из `legacy-pg14`.

## 4) Что в плане безобидно и почему

- **`aws_s3_bucket.artifacts` (`no-op`)**: `before` и `after` совпадают (`"launch-artifacts"`), действий нет — apply для ресурса ничего не делает.
- **`aws_cloudwatch_log_group.api` (`create`)**: создаётся только новый ресурс, существующие не затрагиваются; `retention_in_days: 30` — разумная ретенция, обратимо (удаление лог-группы не влияет на приложение, только на историю логов).
- **`aws_ecs_service.api` (`update`, `desired_count` 2 → 3)**: масштабирование вверх без изменения образа и конфигурации сервиса в видимых полях; откат — вернуть `2`. Риск ограничен стоимостью и ёмкостью кластера.
- **`aws_ecs_task_definition.api` (`replace`)**: сама по себе регистрация новой ревизии безопасна (старая остаётся доступной до deregister), данные не затрагиваются. Риск появляется только если сервис переключат на новую ревизию с изменённым контейнером — а definition в плане не виден.
- **`aws_ssm_parameter.app_env` (`update`)**: изменение одного значения параметра, обратимо (`production → staging`); опасность не в самом действии, а в моменте переключения.

Всё остальное — БД, IAM, security group, удаление parameter group — безобидным назвать нельзя.

## 5) Чего не хватает для безопасного применения

- **Снапшота и бэкапов перед replace БД**: в плане `skip_final_snapshot: true` и `backup_retention_period: 0` — обратное тому, что нужно. Нет `final_snapshot_identifier`.
- **Согласованного окна и плана отката для БД**: нет `maintenance_window`, `apply_immediately`, нет информации о репликах/читателях.
- **Обоснования IAM `*`/`*`**: нет ни комментария, ни ссылки на задачу; нет данных, к каким ролям политика прикреплена (attachments отсутствуют).
- **Сетевого контекста**: нет `vpc_id`, `egress`, `ipv6_cidr_blocks`, идентификатора SG, схемы доступа к SSH (bastion/VPN/SSM).
- **Связки ECS**: сервис обновляет только `desired_count`; не видно, что он возьмёт ревизию `42`. Нет `task_definition`, `launch_type`/`capacity_provider_strategy`, `network_configuration`, `load_balancer`.
- **Полноты плана**: нет `planned_values`, `prior_state`, `configuration`, `output_changes`, `after_unknown` — нельзя проверить drift, порядок операций, unknown-значения и отсутствие других изменений.
- **Окружения и владельца**: не видно workspace/аккаунта/региона/тегов, нет ответственного за прод-БД и за IAM-политику.
- **Проверок**: `checks`, `errored`, `applyable` отсутствуют — статус плана неизвестен; политика `policy/` (шаг 7) даёт warn, но gate `make gate-plan` по этому плану падает, и это ожидаемо.

## Вопросы перед approve

1. Почему `aws_db_instance` пересоздаётся, а не обновляется, и кто согласовал мажорный переход `15.7 → 16.3` — есть ли снапшот, реплика и окно простоя?
2. Кто и зачем расширил `aws_iam_policy` до `Action: "*"` / `Resource: "*"` — какая задача это требует и к каким ролям политика прикреплена?
3. Почему SSH открывается в `0.0.0.0/0` — это временный доступ, есть ли bastion/VPN/SSM и кто отвечает за его закрытие?
4. Кто использует `legacy-pg14` и что произойдёт с инстансом, если группа параметров исчезнет раньше БД?
5. Переключение `app_env` в `production` синхронизировано с деплоем ECS, и получит ли сервис ревизию `42` в этом же apply?
