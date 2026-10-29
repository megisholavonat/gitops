{{/* Env shared by the api-next API, worker and scheduler */}}
{{- define "mhav.apiNext.env" -}}
- name: REDIS_HOST
  value: mhav-next-redis
- name: REDIS_KEY
  value: mhav-api-next
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: mhav-pg-app
      key: uri
- name: GRAPHQL_ENDPOINT
  value: "https://mavplusz.hu//otp2-backend/otp/routers/default/index/graphql"
- name: SOCKS5_PROXY_ENABLE
  value: "true"
{{- range list "SOCKS5_PROXY_HOST" "SOCKS5_PROXY_PORT" "SOCKS5_PROXY_USERNAME" "SOCKS5_PROXY_PASSWORD" }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: mhav-api-app-secret
      key: {{ . }}
{{- end }}
{{- end }}

{{/* Push senders (Expo, APNs Live Activities), used by the API and the worker */}}
{{- define "mhav.apiNext.pushEnv" -}}
# Only needed if the Expo project enforces access tokens
- name: EXPO_ACCESS_TOKEN
  valueFrom:
    secretKeyRef:
      name: expo-secret
      key: EXPO_ACCESS_TOKEN
      optional: true
# iOS Live Activities through APNs; the key comes from the apns-secret
# SealedSecret (see README), optional so pods start without it
- name: APNS_BUNDLE_ID
  value: {{ .Values.apns.bundleId | quote }}
- name: APNS_USE_SANDBOX
  value: {{ .Values.apns.useSandbox | quote }}
{{- range list "APNS_KEY_ID" "APNS_TEAM_ID" "APNS_PRIVATE_KEY" }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: apns-secret
      key: {{ . }}
      optional: true
{{- end }}
{{- end }}
