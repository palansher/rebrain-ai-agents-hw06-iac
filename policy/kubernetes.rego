# Policy для Kubernetes-манифестов (helm render и kubectl kustomize).
# Rego v1 (OPA 1.x): правила объявляются через `contains msg if`.
# Каждое правило проверяет наличие input.kind, поэтому на terraform/plan.json
# (у него нет kind) они не срабатывают.
package main

# ---------------------------------------------------------------------------
# deny 1. Опасные настройки PodSpec: privileged, hostPath, hostNetwork
# ---------------------------------------------------------------------------

deny contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	c.securityContext.privileged == true
	msg := sprintf("%s %q: контейнер %q запущен с privileged: true", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	input.kind != null
	some v in input.spec.template.spec.volumes
	v.hostPath.path
	msg := sprintf("%s %q: том %q монтирует каталог хоста %q через hostPath", [input.kind, input.metadata.name, v.name, v.hostPath.path])
}

deny contains msg if {
	input.kind != null
	input.spec.template.spec.hostNetwork == true
	msg := sprintf("%s %q: включён hostNetwork: true (под в сети хоста)", [input.kind, input.metadata.name])
}

# ---------------------------------------------------------------------------
# deny 2. Образ без закреплённого тега или с тегом latest
# ---------------------------------------------------------------------------

deny contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	image_not_pinned(c.image)
	msg := sprintf("%s %q: контейнер %q использует образ %q без закреплённого тега или с тегом latest", [input.kind, input.metadata.name, c.name, c.image])
}

# digest (@sha256:...) считаем закреплением
image_not_pinned(image) if {
	not contains(image, "@")
	endswith(image, ":latest")
}

image_not_pinned(image) if {
	not contains(image, "@")
	parts := split(image, "/")
	last := parts[count(parts) - 1]
	not contains(last, ":")
}

# ---------------------------------------------------------------------------
# deny 3. Литеральные секреты в env (значение вместо valueFrom.secretKeyRef)
# ---------------------------------------------------------------------------

deny contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	some e in c.env
	secret_like(e.name)
	not e.valueFrom
	e.value != ""
	msg := sprintf("%s %q: контейнер %q передаёт %q литеральным значением в env (нужен valueFrom.secretKeyRef)", [input.kind, input.metadata.name, c.name, e.name])
}

secret_like(name) if {
	regex.match(`(^|_)(TOKEN|PASSWORD|SECRET|KEY|API_KEY|ACCESS_KEY|PRIVATE_KEY)(_|$)`, upper(name))
}

# ---------------------------------------------------------------------------
# warn 4. Non-root: runAsNonRoot должен быть true, runAsUser не должен быть 0
# ---------------------------------------------------------------------------

warn contains msg if {
	input.kind != null
	pod_sc := object.get(input.spec.template.spec, "securityContext", {})
	object.get(pod_sc, "runAsNonRoot", false) != true
	msg := sprintf("%s %q: pod securityContext.runAsNonRoot не выставлен в true", [input.kind, input.metadata.name])
}

warn contains msg if {
	input.kind != null
	input.spec.template.spec.securityContext.runAsUser == 0
	msg := sprintf("%s %q: pod securityContext.runAsUser == 0 (процесс от root)", [input.kind, input.metadata.name])
}

warn contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	c.securityContext.runAsUser == 0
	msg := sprintf("%s %q: контейнер %q имеет runAsUser == 0 (root)", [input.kind, input.metadata.name, c.name])
}

# ---------------------------------------------------------------------------
# warn 5. Нет requests/limits или нет liveness/readiness проб
# ---------------------------------------------------------------------------

warn contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	not c.resources.requests
	msg := sprintf("%s %q: контейнер %q без resources.requests", [input.kind, input.metadata.name, c.name])
}

warn contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	not c.resources.limits
	msg := sprintf("%s %q: контейнер %q без resources.limits", [input.kind, input.metadata.name, c.name])
}

warn contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	not c.livenessProbe
	msg := sprintf("%s %q: контейнер %q без livenessProbe", [input.kind, input.metadata.name, c.name])
}

warn contains msg if {
	input.kind != null
	some c in input.spec.template.spec.containers
	not c.readinessProbe
	msg := sprintf("%s %q: контейнер %q без readinessProbe", [input.kind, input.metadata.name, c.name])
}
