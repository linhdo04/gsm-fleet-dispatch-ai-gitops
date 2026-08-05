{{/* Common labels shared by all Fleet Dispatch resources. */}}
{{- define "fleet-dispatch.labels" -}}
app.kubernetes.io/part-of: {{ .Values.global.partOf }}
{{- end }}

{{/* Stable selector labels are deliberately independent of the Helm release name. */}}
{{- define "fleet-dispatch.backendSelectorLabels" -}}
app.kubernetes.io/name: backend
{{- end }}

{{- define "fleet-dispatch.frontendSelectorLabels" -}}
app.kubernetes.io/name: frontend
{{- end }}

{{- define "fleet-dispatch.image" -}}
{{- $component := index . 0 -}}
{{- $name := index . 1 -}}
{{- printf "%s:%s" (required (printf "%s.image.repository is required" $name) $component.image.repository) (required (printf "%s.image.tag is required" $name) $component.image.tag) -}}
{{- end }}
