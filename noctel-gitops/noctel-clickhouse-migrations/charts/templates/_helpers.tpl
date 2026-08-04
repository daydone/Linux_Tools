{{/*
Resolve target database name. Defaults to noctel_trace_<global.namespace>.
*/}}
{{- define "noctelCh.database" -}}
{{- if .Values.migrations.database -}}
{{ .Values.migrations.database }}
{{- else -}}
noctel_trace_{{ .Values.global.namespace }}
{{- end -}}
{{- end -}}

{{/*
A short release label used on Job/ConfigMap names. We include the chart
revision in the Job name (templates/job-migrate.yaml) so a new sync
creates a fresh Job rather than colliding with the previous completed one.
*/}}
{{- define "noctelCh.fullname" -}}
noctel-ch-migrate-{{ .Values.global.namespace }}
{{- end -}}
