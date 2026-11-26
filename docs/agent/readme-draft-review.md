# Ревью черновика README (P10)

Черновик: `docs/agent/readme-draft.md` (250 строк). Проверял человек; финальный текст — `README.md`.

## Что подтверждено

| Утверждение черновика | Проверка | Итог |
|---|---|---|
| trivy: 21 → 2 (LOW 12/MEDIUM 6/HIGH 3 → LOW 1/MEDIUM 1) | прогон по `/tmp/base.yaml` и `/tmp/cur.yaml` | подтверждено |
| kube-score CRITICAL: 8 → 6 | `kube-score score` + подсчёт | подтверждено |
| kube-linter: 9 → 1 | `kube-linter lint` + подсчёт | подтверждено |
| Kustomize v5.5.0 | строка версии в бинаре kubectl | подтверждено |
| make 4.3, jq 1.7, helm 3.20.0, conftest 0.71.1/OPA 1.21.1 | вывод команд | подтверждено |
| conftest: 51/0/0, 34/5/0, 17/5/0 | прогоны по трём входам | подтверждено |
| baseline kubeconform: 2 Errors (`could not find schema`) | рендер baseline-чарта с `--set serviceAccount.create=false` | подтверждено |

## Что исправлено в финальном README

1. **«Инъекцию нашли на шаге 4»** — неверно. Она найдена на этапе аудита, **до** правок, поиском по репозиторию;
   валидаторы её не видят. В README §10 исправлено.
2. **Цитата «я поторопился с изменением README.md и REVIEW.md»** — в сессии отсутствует, агент такого не говорил.
   Реальная цитата P6.1: «Два решения, которые стоит подтвердить: conftest вызывается с `--fail-on-warn`…».
   В README §3/§4 исправлено.
3. **«kubeconform поймал опечатки `containerPorts`/`livenessProb` в baseline»** — нет: для `apps/v1beta2`
   схемы в 1.29 не существует, был только `could not find schema`. Опечатки подтверждены **негативным тестом**
   после смены apiVersion (`additional properties ... not allowed`). В README §6 разделено.
4. **TODO по PDB и Ingress** — закрыты экспериментом: `could not find schema for PodDisruptionBudget`;
   `missing property pathType` + `additional properties serviceName, servicePort`.
5. **P9** — чеклист написан человеком, промпта нет; в README §3/§7 это указано явно, а не как TODO.

## Что не принято

- Формулировки, где «8/8» звучит как цель: в финале подчёркнуто, что табло — индикатор, а не доказательство.
- Раздел «Источники» сохранён (полезен), TODO-список разобран по пунктам.

Итог: структура и факты черновика приняты; финальный текст переписан человеком с исправлениями выше.
