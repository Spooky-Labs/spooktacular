{{/*
=============================================================================
Spooktacular Helm Chart — Template Helpers
=============================================================================
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "spooktacular.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
Truncated at 63 characters because Kubernetes name fields are limited to this.
*/}}
{{- define "spooktacular.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label value.
*/}}
{{- define "spooktacular.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Standard labels applied to every resource.
*/}}
{{- define "spooktacular.labels" -}}
helm.sh/chart: {{ include "spooktacular.chart" . }}
{{ include "spooktacular.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — used by the Deployment and Service to match pods.
*/}}
{{- define "spooktacular.selectorLabels" -}}
app.kubernetes.io/name: {{ include "spooktacular.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "spooktacular.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "spooktacular.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Controller image with tag.
*/}}
{{- define "spooktacular.controllerImage" -}}
{{- $tag := default .Chart.AppVersion .Values.controller.image.tag }}
{{- printf "%s:%s" .Values.controller.image.repository $tag }}
{{- end }}
