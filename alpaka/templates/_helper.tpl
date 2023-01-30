{{/*
Kafka 커넥터 등록 데이터
*/}}
{{- define "connector.data" -}}
    {{ $global := .global }}
    {
    "name": "{{ .cname }}",
    "config": {
    {{- $last := sub (len .mcfg) 1 }}
    {{- $index := 0 }}
    {{- range $k, $v := .mcfg }}
    {{- if eq (typeOf $v) "string" }}
        {{- if ne $k "query" }}
        {{ $k | quote }}: {{ tpl $v $global | quote }}
        {{- else }}
        {{/* 쿼리문은 템플릿으로 처리 않음 */}}
        {{- $k | quote }}: "{{ range (split "\n" $v ) }}{{ printf "%s\\n" . }}{{- end }}"
        {{- end }}
    {{- else if has (typeOf $v) ( list "int" "float64" ) }}
        {{ $k | quote }}: "{{ mul $v 1 }}"
    {{- else }}
        {{ $k | quote }}: "{{ $v }}"
    {{- end }}
    {{- if ne $index $last }},{{ end }}
    {{- $index = add1 $index }}
    {{- end }}
    }
    }
{{- end }}


{{/*
Kafka connector register script

Replace old connector only if data changed.

*/}}
{{- define "connector.register" -}}
    {{- $mcfg := merge .cfg .com }}
    {{- $vals := merge .gvals .cvals }}
    {{- $global := (dict "Template" .global.Template "Values" $vals ) }}
    # new connector data
    newdata=$(mktemp)
    echo "new data file: $newdata"
    cat <<EOT > $newdata 
    {{ include "connector.data" ( dict "cname" .cname "mcfg" $mcfg "global" $global ) }}
    EOT
    # simplify new data to compare
    jq ".config" --sort-keys $newdata > $newdata-2dif
    # if previous connector exsiting
    if curl --output /dev/null --silent --head --fail "{{ .cnt_url }}/connectors/{{ .cname }}"; then
        # get old data
        olddata=$(mktemp)
        echo "old data file: $olddata"
        # simplify old data to compare
        curl -s -X GET "{{ .cnt_url }}/connectors/{{ .cname }}" | jq ".config" --sort-keys > $olddata 
        jq "del(.name)" --sort-keys $olddata > $olddata-2dif
        # if data has changed
        diff -w -B $olddata-2dif $newdata-2dif > /dev/null
        changed=$?
        if [ $changed -ne 0 ];
        then 
            echo "Connector '{{ .cname }}' has changed!"
            # delete exsiting connector
            echo "Delete existing connector '{{ .cname }}'"
            curl -s -X DELETE "{{ .cnt_url }}/connectors/{{ .cname }}"
            # register connector with new data after a while
            sleep 5
            echo "Replace connector '{{ .cname }}'"
            curl -s -X POST {{ .cnt_url }}/connectors -H "Content-Type: application/json" -d "@$newdata" | jq
        else
            echo "Connector '{{ .cname }}' has not changed."
        fi
    # first register
    else 
        echo "Register new connector '{{ .cname }}'"
        curl -s -X POST {{ .cnt_url }}/connectors -H "Content-Type: application/json" -d "@$newdata" | jq
    fi
{{- end }}

{{/*
Kafka 커넥터 등록 스크립트 파일명
*/}}
{{- define "connector.filename" -}}
  {{- printf "%s-%s-%s.sh" .cnt_type .grp_name .con_name }}
{{- end -}}