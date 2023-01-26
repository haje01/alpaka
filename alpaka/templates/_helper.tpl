{{/*
Kafka 커넥터 등록 스크립트 
*/}}
{{- define "connector.register" -}}
    {{- $mcfg := mergeOverwrite .com .cfg }}
    {{- $vals := mergeOverwrite .cvals .gvals }}
    {{- $global := (dict "Template" .global.Template "Values" $vals ) }}
    curl -s -X POST {{ .cnt_url }}/connectors -H "Content-Type: application/json" -d '{
        "name": "{{ .cname }}",
        "config": {
        {{- $last := sub (len $mcfg) 1 }}
        {{- $index := 0 }}
        {{- range $k, $v := $mcfg }}
        {{- if eq (typeOf $v) "string" }}
            {{- if ne $k "query" }}
            {{ $k | quote }}: {{ tpl $v $global | quote }}
            {{- else }}
            {{/* 쿼리문은 템플릿으로 처리 않음 */}}
            {{- $k | quote }}: "{{ range (split "\n" $v ) }}{{ printf "%s\\n" (. | replace "'" "'\\''" ) }}{{- end }}"
            {{- end }}
        {{- else if has (typeOf $v) ( list "int" "float64" ) }}
            {{ $k | quote }}: {{ mul $v 1 }}
        {{- else }}
            {{ $k | quote }}: {{ $v }}
        {{- end }}
        {{- if ne $index $last }},{{ end }}
        {{- $index = add1 $index }}
        {{- end }}
        }
    }' | jq
{{- end }}

{{/*
Kafka 커넥터 등록 스크립트 파일명
*/}}
{{- define "connector.filename" -}}
  {{- printf "%s-%s-%s.sh" .cnt_type .grp_name .con_name }}
{{- end -}}