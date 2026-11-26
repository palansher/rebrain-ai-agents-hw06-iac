# Policy для terraform/plan.json.
# Все правила начинаются с `some rc in input.resource_changes`, поэтому на
# Kubernetes-манифестах (у них нет resource_changes) не срабатывают.
package main

# ---------------------------------------------------------------------------
# warn 6. delete/replace stateful-ресурса — риск потери данных
# ---------------------------------------------------------------------------

warn contains msg if {
	some rc in input.resource_changes
	"delete" in rc.change.actions
	stateful_types[rc.type]
	msg := sprintf("%s (%s): stateful-ресурс затрагивается действием %q — риск потери данных", [rc.address, rc.type, concat("/", rc.change.actions)])
}

stateful_types := {
	"aws_db_instance",
	"aws_db_cluster",
	"aws_rds_cluster",
	"aws_db_parameter_group",
	"aws_s3_bucket",
	"aws_ebs_volume",
	"aws_efs_file_system",
	"aws_dynamodb_table",
	"aws_elasticache_cluster",
	"aws_elasticache_replication_group",
	"aws_redshift_cluster",
	"aws_sqs_queue",
	"aws_kms_key",
	"aws_secretsmanager_secret",
}

# ---------------------------------------------------------------------------
# warn 7. Security group ingress, открытый для 0.0.0.0/0 (порт 22 — отдельно)
# ---------------------------------------------------------------------------

warn contains msg if {
	some rc in input.resource_changes
	some ing in rc.change.after.ingress
	some cidr in ing.cidr_blocks
	world_open(cidr)
	not ssh_range(ing)
	from := object.get(ing, "from_port", 0)
	to := object.get(ing, "to_port", 65535)
	msg := sprintf("%s: ingress открыт для %s (порты %v-%v) — доступ из всего интернета", [rc.address, cidr, from, to])
}

warn contains msg if {
	some rc in input.resource_changes
	some ing in rc.change.after.ingress
	some cidr in ing.cidr_blocks
	world_open(cidr)
	ssh_range(ing)
	msg := sprintf("%s: SSH (порт 22) открыт для %s — оставьте доступ только из bastion/VPN", [rc.address, cidr])
}

world_open(cidr) if cidr == "0.0.0.0/0"

world_open(cidr) if cidr == "::/0"

ssh_range(ing) if {
	from := object.get(ing, "from_port", 0)
	to := object.get(ing, "to_port", 65535)
	from <= 22
	to >= 22
}

# ---------------------------------------------------------------------------
# warn 8. IAM-политика с Action "*" или Resource "*"
# ---------------------------------------------------------------------------

warn contains msg if {
	some rc in input.resource_changes
	policy_doc := json.unmarshal(rc.change.after.policy)
	some st in statements(policy_doc)
	wildcard(st.Action)
	msg := sprintf("%s: IAM-политика разрешает Action \"*\" — полные права на действия", [rc.address])
}

warn contains msg if {
	some rc in input.resource_changes
	policy_doc := json.unmarshal(rc.change.after.policy)
	some st in statements(policy_doc)
	wildcard(st.Resource)
	msg := sprintf("%s: IAM-политика разрешает Resource \"*\" — права на все ресурсы", [rc.address])
}

# Statement бывает и массивом, и объектом
statements(doc) := list if {
	list := doc.Statement
	is_array(list)
}

statements(doc) := [doc.Statement] if {
	not is_array(doc.Statement)
}

wildcard(v) if v == "*"

wildcard(v) if {
	is_array(v)
	some x in v
	x == "*"
}
