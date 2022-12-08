# 참조 파일

이 디렉토리에는 Helm Install 시 직간접 적으로 필요한 파일을 둔다.

## Grafana 관련 

### Zookeeper

Zookeeper 메트릭을 노출하는 대쉬보드

[zookeeper-by-prometheus_rev4](https://grafana.com/grafana/dashboards/10465-zookeeper-by-prometheus/)

만약 Zookeeper 대쉬보드의 새 버전이 나오면, 이 디렉토리에 덮어 쓰고 `$DS_PROMETHEUS` 을 모두 `Prometheus` 로 대체한다.

### KMinion 

KMinion 은 KMinion Exporter 가 익스포트한 카프카 메트릭을 다음과 같은 3 개 대쉬보드 JSON 파일을 이용해 대쉬보드로 노출한다. 이 디렉토리에 각 파일이 있다.

- [kminion-cluster_rev1.json](https://grafana.com/grafana/dashboards/14012-kminion-cluster/)
- [kminion-topic_rev1.json](https://grafana.com/grafana/dashboards/14013-kminion-topic/)
- [kminion-groups_rev1.json](https://grafana.com/grafana/dashboards/14014-kminion-groups/)


만약 KMinion 대쉬보드의 새 버전이 나오면, 이 디렉토리에 덮어 쓰고 `${DS_CORTEX}` 을 모두 `Prometheus` 로 대체한다. 필요시 `configmaps/grafana-dashboards.yaml` 파일도 수정한다.

> ** Grafana 에서 대쉬보드 이동시 계속 세이브 창이 뜨는 경우 **
> Grafana 가 자동으로 대쉬보드를 최신 포맷으로 변경한 경우다. 대쉬보드의 Save Dashboard 클릭 후 Copy JSON to clipboard 후 이 디렉토리의 파일에 Paste 하여 갱신된 버전으로 저장한다.

### JMX Overview

JMX Exporter 가 익스포트한 JVM 메트릭 대쉬보드 

[altassian-overview_rev1](https://grafana.com/grafana/dashboards/3457-altassian-overview/)