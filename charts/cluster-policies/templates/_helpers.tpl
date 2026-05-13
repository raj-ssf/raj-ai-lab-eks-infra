{{/*
Render the combined exclude-namespaces list (global defaults + per-policy
extra). Used in every policy's exclude block.
*/}}
{{- define "policies.excludeNamespaces" -}}
{{- $extra := index . 1 | default (list) -}}
{{- $globals := (index . 0).Values.global.defaultExcludeNamespaces -}}
{{- $all := concat $globals $extra | uniq -}}
{{- toYaml $all -}}
{{- end -}}

{{/*
Render the validationFailureAction: "audit" or "enforce".
Wraps both the legacy validate.message-level field and the modern
ClusterPolicy.spec.validationFailureAction (Kyverno >= 1.10 uses
the spec-level field).
*/}}
{{- define "policies.action" -}}
{{- $v := . -}}
{{- if not (or (eq $v "audit") (eq $v "enforce")) -}}
{{- fail (printf "policy action must be 'audit' or 'enforce', got: %s" $v) -}}
{{- end -}}
{{- $v -}}
{{- end -}}
