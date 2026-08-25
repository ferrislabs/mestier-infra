{{/*
NOTE ON NAMING: this wrapper chart and the bundled upstream chart are both
literally named "kargo" (Chart.yaml `name: kargo` on both sides). Upstream
already defines templates named "kargo.name", "kargo.labels",
"kargo.selectorLabels", etc. (see the `kargo` dependency's own
templates/_helpers.tpl) — `define` names are global across a chart and all
its subcharts, so reusing "kargo.*" here would silently redefine (or be
shadowed by) upstream's own helpers. Every helper below is therefore prefixed
"kargo-platform" instead of "kargo", unlike the charts/argocd model (which
could safely use "argocd.*" because its dependency is named "argo-cd", not
"argocd").
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "kargo-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kargo-platform.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "kargo-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kargo-platform.labels" -}}
helm.sh/chart: {{ include "kargo-platform.chart" . }}
{{ include "kargo-platform.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kargo-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kargo-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Validate chart values before rendering resources. Produces no output; fails
the render with a clear message when a required value is missing.
*/}}
{{- define "kargo-platform.validate" -}}
{{- if .Values.httpRoute.create -}}
{{- if not .Values.host -}}
{{- fail "host is required when httpRoute.create is true" -}}
{{- end -}}
{{- if not .Values.gateway.name -}}
{{- fail "gateway.name is required when httpRoute.create is true" -}}
{{- end -}}
{{- if not .Values.gateway.namespace -}}
{{- fail "gateway.namespace is required when httpRoute.create is true" -}}
{{- end -}}
{{- if not .Values.httpRoute.serviceName -}}
{{- fail "httpRoute.serviceName is required when httpRoute.create is true" -}}
{{- end -}}
{{- if not .Values.httpRoute.servicePort -}}
{{- fail "httpRoute.servicePort is required when httpRoute.create is true" -}}
{{- end -}}
{{- end -}}
{{- if .Values.argocdRbac.create -}}
{{- if not .Values.argocdRbac.namespace -}}
{{- fail "argocdRbac.namespace is required when argocdRbac.create is true" -}}
{{- end -}}
{{- if not .Values.argocdRbac.serviceAccountName -}}
{{- fail "argocdRbac.serviceAccountName is required when argocdRbac.create is true" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "kargo-platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kargo-platform.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
