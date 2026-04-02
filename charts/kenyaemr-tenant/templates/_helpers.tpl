{{- define "kenyaemr-tenant.fullname" -}}
{{- printf "%s-%s" .Release.Name "kenyaemr" | trunc 63 | trimSuffix "-" -}}
{{- end -}}
