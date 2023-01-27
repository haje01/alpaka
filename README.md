# alpaka

[카프카](https://kafka.apache.org/)는 분산형 데이터 스트리밍 플랫폼인데, 설정이 복잡하고 함께 연계하여 사용하는 서비스도 다양해 설치가 좀 까다롭다. 알파카는 Kubernetes 클러스터에 Kafka + 관련 패키지를 쉽게 배포하기 위한 Helm 차트이다. 다음과 같은 패키지를 포함한다:

- Kafka
- Zookeeper
- Kafka 용 JDBC 커넥터
- UI for Kafka
- Prometheus (+ KMinion)
- Grafana (+ 각종 대쉬보드)
- Kubernetes Dashboard
- 테스트용 MySQL

추가적으로 테스트 및 운영을 위해 '알파카 Tool' 컨테이너가 설치된다.

## 사전 준비

OS 는 도커의 특성상 리눅스만 지원한다. 여기에 먼저 지원 툴인 [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) 과 [Helm](https://helm.sh/docs/intro/install/) 을 설치하여야 한다. 각각의 링크를 참고하여 진행하자.

다음은 사용할 쿠버네티스 배포판을 선택해야 한다. 개발용으로는 로컬 쿠버네티스 배포판을, 프로덕션 용도로는 클라우드 또는 IDC 용 배포판을 이용할 수 있다. 알파카는 로컬용으로 [minikube](https://minikube.sigs.k8s.io/docs/), [k3s](https://k3s.io/) 및 [k3d](https://k3d.io/v5.4.6/) 를, 프로덕션용으로 [AWS EKS](https://aws.amazon.com/ko/eks/) 을 위한 설정 파일을 기본으로 제공한다. 

다른 배포판 환경에도 조금만 응용하면 무리없이 적용할 수 있을 것이다.

### 로컬 쿠버네티스 배포판 관련

로컬 쿠버네티스 환경에서는 메모리가 너무 작으면 파드가 죽을 수 있고, 디스크 용량이 너무 작으면 PVC 할당이 안될 수 있으니 주의하자. 

#### minikube 이용시

코어 4개, 메모리 8GB, 디스크 40GB 예:
```
minikube start --cpus=4 --memory=10g --disk-size=40g
```

#### k3d 이용시 

워커노드 5 대, 노드별 메모리 2GB 예:

```
k3d cluster create --agents=5 --agents-memory=2gb
```

### 클라우드 쿠버네티스 환경 (AWS EKS) 관련

여기서는 AWS EKS (관리형 쿠버네티스 서비스) 기준으로 설명한다.

#### 클러스터 만들기 

아래는 클러스터 이름 `prod`, EC2 `m5.xlarge` 타입 4대, 디스크 100GB 최대 4대인 예이다. 참고하여 필요한 사양의 클러스터를 만들도록 하자.

```bash
eksctl create cluster \
--name prod \
--nodegroup-name xlarge \
--node-type m5.xlarge \
--node-volume-size 100 \
--nodes 1 \
--nodes-min 1 \
--nodes-max 4
```

> AWS EKS 클러스터의 경우 사용을 마쳤으면 꼭 제거해 비용을 절감하도록 하자.
> 
> ```
> eksctl delete cluster --name prod
> ```

#### 스토리지 프로비저닝 준비 

클러스터 생성후 PVC 를 통한 스토리지 할당을 받기 위해 아래 작업이 필요하다.
( 참고 : [Creating an IAM OIDC provider for your cluster](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html) )

1. 기존 OIDC 존재 확인
```bash
oidc_id=$(aws eks describe-cluster --name prod --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
```

2. 클러스터 ID 의 IAM OIDC 프로바이더가 계정에 있는지 확인 

```bash
aws iam list-open-id-connect-providers | grep $oidc_id
```

3. 결과가 없으면 IAM OIDC 아이덴터티 생성
```bash
eksctl utils associate-iam-oidc-provider --cluster prod --approve
```

4. 서비스 계정을 위한 EBS CSI 드라이버용 IAM Role 생성
( 참고 : [Creating the Amazon EBS CSI driver IAM role for service accounts](https://docs.aws.amazon.com/eks/latest/userguide/csi-iam-role.html) )

```bash
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster prod \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --role-only \
  --role-name AmazonEKS_EBS_CSI_DriverRole
```

5. EKS 애드온으로 EBS CSI 드라이버 설치하기
( 참고 : [Managing the Amazon EBS CSI driver as an Amazon EKS add-on](https://docs.aws.amazon.com/eks/latest/userguide/managing-ebs-csi.html) )
```bash
eksctl create addon --name aws-ebs-csi-driver --cluster prod --service-account-role-arn arn:aws:iam::<AWS 계정 번호>:role/AmazonEKS_EBS_CSI_DriverRole --force
```

#### EKS 용 인그레스 (Ingress) 준비 

알파카로 설치되는 다양한 서비스의 웹페이지를 외부에서 접근하기 위해서 인그레스가 필요하다. EKS 를 이용하는 경우 인그레스를 사용하기 전에 클러스터 생성후 아래 작업이 필요하다.

AWS 로드밸런서 컨트롤러 설치
( 참고 : [Installing the AWS Load Balancer Controller add-on](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html) )

1. IAM Policy 생성 ( 정책 이름 : `AWSLoadBalancerControllerIAMPolicy` )

`etc/eks/` 디렉토리로 이동 후 다음과 같이 실행한다.
```bash
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

2. IAM Role 만들기( 역할 이름 : `AmazonEKSLoadBalancerControllerRole` )
```bash
eksctl create iamserviceaccount \
  --cluster=prod \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name "AmazonEKSLoadBalancerControllerRole" \
  --attach-policy-arn=arn:aws:iam::<AWS 계정 번호>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

4. Helm 으로 EKS 용 Load Balancer Controller 설치

차트 저장소 추가
```bash
helm repo add eks https://aws.github.io/eks-charts
```

로컬 저장소 갱신
```bash
helm repo update
```

차트 설치
```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=prod \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller 
```

> 참고: 배포된 차트의 보안 업데이트
>
> ```kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"```

설치 확인

```kubectl get deployment -n kube-system aws-load-balancer-controller```

이제 AWS EKS 에서 인그레스를 이용할 준비가 되었다. AWS EKS 의 경우 도메인 명으로 접속하려면 퍼블릭 도메인과 ACM 인증서가 필요하기에, 여기서는 도메인 없이 포트로 서비스를 구분하여 사용하는 것으로 설명하겠다. `configs/_eks.yaml` 설정 파일을 보면 이를 위해 설정 파일에서 서비스 별로 인그레스를 서로 다른 포트로 요청하는 것을 확인할 수 있다. 

> 퍼블릭 도메인을 이용하는 경우:
> AWS ACM 으로 가서 퍼블릭 도메인을 위한 인증서를 만들어 주고 그 ARN 을 아래와 같이 `annotations` 아래에 기재하여야 한다.
> ```
> alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-2:111122223333:certificate/11fceb32-9cc2-4b45-934f-c8903e4f9e12 
> alb.ingress.kubernetes.io/ssl-redirect: '443'
> ```

### 부속 컨테이너 이미지  

카프카나 그라파나 같은 패키지를 설치할 때는 공개된 공식 컨테이너 이미지를 이용하면 된다. 그런데 알파카가 이용하는 컨테이너 이미지는 직접 만들어 주어야 할 경우가 있기에 여기서 소개한다. 현재 부속 이미지는 툴 및 DB 커넥터용의 두 가지가 있다.

#### 툴 컨테이너 이미지

서비스를 위한 컨테이너 이미지는 용량, 속도, 보안 등의 이슈로 대부분 서비스에 꼭 필요한 실행 파일만 설치되어 있다. 그런데 패키지를 설치하고 운용하다 보면 여러가지 문제가 발생하기에, 이를 찾고 고치기 위한 실행파일이 설치된 이미지가 있으면 편리하다. 알파카에서는 이것을 툴 컨테이너 이미지라고 부른다. 

여기에는 vim, kcat, jq, 파이썬 및 DNS 유틸 등이 설치되어 있기에 클러스터 내 다른 컨테이너의 동작을 확인하거나 네트워크 이슈를 찾는 등 다양한 작업을 할 수 있다. 기본 툴 이미지는 [도커 허브의 haje01/alpaka-tool](https://hub.docker.com/repository/docker/haje01/alpaka-tool/general) 로 올라가 있기에 이것을 사용하면 된다. 


> 만약 독자적인 툴 이미지가 필요하면 `images/Dockerfile.tool` 및 `images/build_tool.sh` 파일을 참고하여 만들도록 하자.

#### DB 커넥트 이미지 

카프카의 커넥터 (Connector) 는 다양한 데이터 소스에서 데이터를 가져오거나, 외부로 내보내는 데 사용되는 일종의 플러그인이다. 커넥터는 카프카 커넥트 (Connect) 장비에 등록되어 동작하는데, 알파카에서는 기본적으로 [Confluent JDBC 커넥터](https://docs.confluent.io/kafka-connectors/jdbc/current/index.html) 및 [Debezium](https://debezium.io/) 이 설치된 DB 용 커넥트 이미지를 제공한다.


기본 DB 커넥트 이미지는 [도커 허브의 haje01/kafka-dbcon](https://hub.docker.com/repository/docker/haje01/kafka-dbcon/general) 으로 올라가 있기에 이것을 사용하면 된다. 

> 만약 독자적인 DB 커넥터 이미지가 필요하면 `images/Dockerfile.dbcon` 및 `images/build_dbcon.sh` 파일을 참고하여 만들도록 하자.


## 설정 파일 만들기 

설치를 위해서는 먼저 설정 파일이 필요하다. `configs/` 디렉토리에 아래와 같은 샘플 설정 파일이 있으니 참고하여 자신의 필요에 맞는 설정 파일을 만들어 사용한다 (샘플 설정 파일은 구분하기 쉽게 `_` 로 시작한다):
- `_mkb.yaml` - minikube 용
- `_k3s.yaml` - k3s 용
- `_k3d.yaml` - k3d 용
- `_eks.yaml_` - eks 용

> 여기서는 참고용으로 쿠버네티스 배포판별 설정 파일을 만들었지만 꼭 이렇게 할 필요는 없다. 실제로는 한 번 선택한 쿠버네티스 배포판 자주 바뀌지 않기에 개발/테스트/라이브 등의 용도별로 설정 파일을 만드는 것이 더 적합할 것이다.

> `alpaka/values.yaml` 는 차트에서 사용하는 기본 변수값을 담고 있다. 위의 파일들과 함께 참고하여 커스텀 설정 파일을 만들 수 있다.

설정 파일은 .yaml 파일로 최상위 블럭만 표시하면 다음과 같은 구조를 가진다.

```yaml
k8s_dist:       # 쿠버네티스 배포판 종류 (minikube, k3s, k3d, eks 중 하나)

kafka:          # 카프카 설정 

kafka_connect:  # 카프카 커넥트 및 커넥터 설정 

ui4kafka:       # UI for Kafka 설정

k8dashboard:    # 쿠버네티스 대쉬보드 설정 

prometheus:     # 프로메테우스 설정

grafana:        # 그라파나 설정 

kminion:        # 그라파나 용 KMinion 대쉬보드 설정 

ingress:        # 공용 인그레스 설정

init:           # 클러스터 설치 후 초기화 설정 

test:           # 클러스터 설치 후 테스트 설정 
```

`k8s_dist`, `kminion`, `ingress`, `kafka_connect`, `init` 그리고 `test` 는 알파카 내부 설정이다. `kafka`, `ui4kafka`, `k8dashboard`, `prometheus`, `grafana` 는 알파카가 의존하는 외부 패키지를 위한 설정이다.

지금부터는 테스트를 위한 간단한 설정 파일을 만들어 가면서 설정 파일 작성 방법을 소개하겠다. 이 설정 파일은 로컬에서 minikube 배포판을 이용하고, 파일은 `configs/test.yaml` 에 저장하는 것으로 가정하겠다. 파일의 초기 내용은 아래와 같을 것이다.

```yaml
k8s_dist: minikube
```

이 설정 파일이 완성되면 다음과 같이 설치하게 될 것이다.

```
helm install -f configs/test.yaml mytest alpaka/
```

이 경우 배포 이름은 `mytest` 가 된다. 

지금부터 각 설정 블럭을 차례대로 설명하겠다. 알파카 차트나 알파카 변수 파일 `alpaka/values.yaml` 에 기본값이 지정되어 있고 설정 파일에 관련 내용이 없으면 기본값이 이용된다.

### 카프카 설정 

카프카 클러스터 및 주키퍼 관련 내용을 여기서 설정한다. 대략의 구조는 아래와 같다.

```yaml
kafka: 
  replicaCount: 1              # 카프카 브로커의 수. HA 구성을 위해서는 3 을 추천 
  defaultReplicationFactor: 1  # 토픽 복제 수. 브로커 수가 3 인 경우 2 를 추천 
  numPartitions: 8             # 토픽별 파티션 수
```

기본 값은 브로커 1 대, 파티션 수 8 개로 이대로 사용하고자 하면 별도의 `kafka` 블럭을 지정하지 않아도 클러스터가 만들어진다.

카프카는 [bitnami 의 kafka Helm 차트](https://bitnami.com/stack/kafka/helm) 를 이용하였다. 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values bitnami/kafka
```

### 카프카 커넥트 설정 

카프카 커넥터는 데이터를 카프카로 가져오거나 외부로 내보내기 위한 일종의 플러그인이다. 커넥트는 커넥터를 기동하기 위한 장비로 생각하면 간단하다.

아래는 JDCB 소스 커넥트를 이용하기 위한 예로, 여기서는 MySQL 에 있는 `mydb` 라는 DB 에서 로그성 테이블 `log1` 과 `log2` 그리고 코드성 테이블 `code` 를 가져오는 경우를 가정하였다.

> 이 예는 어디까지나 설명을 위한 것으로 실제 커넥터 설정은 좀 더 상세한 설정이 필요하다.

```yaml
kafka_connect:
  enabled: true       # 커넥트를 사용하면 true.
  # 커넥트 정보
  connects:           # 이 블록아래 커넥트를 종류별로 기술 
  - type: jdbcsrc        # 커넥트 타입 정보. 여기서는 JDBC 소스 커넥터 타입 
    replicaCount: 1      # 커넥트 파드 수
    # 컨테이너 정보 
    container:                     
      image: "haje01/kafka-dbcon"    # 컨테이너 이미지 
      tag: latest                    # 이미지 태그 
      pullPolicy: IfNotPresent       # 이지미 풀 정책 
    timezone: Asia/Seoul # 커넥트 파드의 타임존 
    # 커넥트 레벨에서 공유될 변수 값 리스트 
    values:                    
      db_ip: mysql-db-addr        # DBMS IP 주소
      db_name: mydb               # DB 이름 
      db_user: myuser             # DB 유저
      db_pass: mypass             # DB 유저 암호 
    # 커넥터 그룹 리스트 
    connector_groups:          
    # DB 내 로그성 테이블을 가져오기 위한 커넥터 그룹 
    - name: mydb_log  # 커넥터 그룹 이름 
      # 그룹내 커넥터 공통 설정
      common:
        connector.class: io.confluent.connect.jdbc.JdbcSourceConnector    # 커넥터 클래스 
        tasks.max: "1"   # 커넥터 동시성 수 
        connection.url: "jdbc:mysql://{{ .Values.db_ip }};databaseName={{ .Values.db_name }}" # 커넥터 접속 URL
        connection.password: "{{ .Values.db_pass }}"  # DB 유저 암호
        mode: incrementing  # 소스 커넥터의 동작 모드 
        incrementing.column.name: id  # incrementing 동작 기준 컬럼 
      # 커넥터별 설정 
      connectors:
      - name: "log1"   # 커넥터 이름. 여기서는 대상 DB 테이블 이름과 같게 하였음 
        config:
          topic.prefix: log1  # 카프카 토픽 접두사 
          query: "SELECT * FROM log1"  # 데이터를 가져올 쿼리문
      - name: "log2"
        config:
          topic.prefix: log2
          query: "SELECT * FROM log2"
    # DB 내 코드 테이블을 가져오기 위한 커넥터 그룹 
    - name: mydb_code  # 커넥터 그룹 이름 
      # 커넥터별 설정 
      connectors:
      # C_Code
      - name: "code"
        config:
          connector.class: io.confluent.connect.jdbc.JdbcSourceConnector    # 커넥터 클래스 
          tasks.max: "1"   # 커넥터 동시성 수 
          connection.url: "jdbc:mysql://{{ .Values.db_ip }};databaseName={{ .Values.db_name }}" # 커넥터 접속 URL
          connection.password: "{{ .Values.db_pass }}"  # DB 유저 암호
          mode: "bulk"        # 소스 커넥터의 동작 모드 
          topic.prefix: code  # 카프카 토픽 접두사 
          query: |            # 데이터를 가져올 쿼리문
            SELECT 
              CURRENT_TIMESTAMP() AS regtime,
              code, desc
            FROM code
```

`kafka_connect.connect` 블록 아래에 하나 이상의 커넥트 정보를 기술할 수 있다.

각 커넥터 설정은 일종의 템플릿이다. 텍스트내에 `{{ .Values.~ }}` 형식으로 기술하면 관련 변수가 있는 경우 대체된다. 

변수는 커넥트 레벨, 커넥트 그룹 레벨의 `values` 블럭에서 기술되고 그룹 아래 각 커넥터의 설정값 텍스트에서 사용되어 진다. 중복된 변수 값이 있으면 가까운 값을 이용하게 된다. 예를 들어 다음과 같이 변수의 값이 지정되어 있다면 :

```yaml
connects:
  values:
    A: 1
  connector_groups:
  - name: group1
    values:
      A: 2
      B: 1
    connectors:
    - name: connector1
      config:
        A_is: {{ .Values.A }}
        B_is: {{ .Values.B }}
```

최종 설정에서 `A_is: 2`, `B_is: 1` 과 같게 된다. 

커넥터의 설정 값도 비슷한 방식으로 커넥터 그룹의 `common` 블럭 및 개별 커넥터의 `config` 블럭의 값이 결합되어 사용된다.

최종 결과물은 각 커넥터 별로 등록 가능한 쉘 스크립트 형식으로 저장되는데, 그것은 `[커넥트 타입]-[커넥터 그룹]-[커넥터 이름].sh` 형식 이름의 실행가능한 파일로 뒤에서 설명할 **초기화 파드** 에 저장된다. 

위 설정 예제의 경우 초기화 파드 `/usr/local/bin` 디렉토리 아래 다음과 같은 세가지 파일이 생성된다.

```
jdbcsrc-mydb_log-log1.sh
jdbcsrc-mydb_log-log2.sh
jdbcsrc-mydb_code-code.sh
```

각 파일의 내용은 다음과 같다.

`jdbcsrc-mydb_log-log1.sh`
```
curl -s -X POST http://test-alpaka-connect-jdbcsrc:8083/connectors -H "Content-Type: application/json" -d '{
    "name": "jdbcsrc-mydb_log-log1.sh",
    "config": {
        "connection.password": "mypass",
        "connection.url": "jdbc:mysql://mysql-db-addr;databaseName=mydb",
        "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
        "incrementing.column.name": "id",
        "mode": "incrementing",
        "query": "SELECT * FROM log1\n",
        "tasks.max": "1",
        "topic.prefix": "log1"
    }
}' | jq
```

`jdbcsrc-mydb_log-log2.sh`
```
curl -s -X POST http://test-alpaka-connect-jdbcsrc:8083/connectors -H "Content-Type: application/json" -d '{
    "name": "jdbcsrc-mydb_log-log2.sh",
    "config": {
        "connection.password": "mypass",
        "connection.url": "jdbc:mysql://mysql-db-addr;databaseName=mydb",
        "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
        "incrementing.column.name": "id",
        "mode": "incrementing",
        "query": "SELECT * FROM log2\n",
        "tasks.max": "1",
        "topic.prefix": "log2"
    }
}' | jq
```

`jdbcsrc-mydb_code-code.sh`
```
curl -s -X POST http://test-alpaka-connect-jdbcsrc:8083/connectors -H "Content-Type: application/json" -d '{
    "name": "jdbcsrc-mydb_code-code.sh",
    "config": {
        "connection.password": "mypass",
        "connection.url": "jdbc:mysql://mysql-db-addr;databaseName=mydb",
        "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
        "mode": "bulk",
        "query": "SELECT \n  CURRENT_TIMESTAMP() AS regtime,\n  code, desc\nFROM code\n\n",
        "tasks.max": "1",
        "topic.prefix": "code"
    }
}' | jq
```

`curl` 을 통해 카프카 커넥트의 API 를 호출하여 각 커넥터를 등록하는 것을 확인할 수 있다.

### UI for Kafka 설정

[UI for Kafka](https://github.com/provectus/kafka-ui) 는 카프카 클러스터의 관리 및 모니터링에 사용된다. 이를 위해 연결할 카프카 브로커, 주키퍼 그리고 필요한 경우 커넥트 정보를 기술해주어야 한다. 일반적으로 다음과 같은 구성이다.

```yaml
ui4kafka:
  enabled: true           # UI for Kafka 를 이용하는 경우 true
  yamlApplicationConfig:  
    kafka:                # 연결할 카프카 클러스터 정보 
      clusters:
      - name: [배포 이름]-kafka   # 클러스터 이름 
        bootstrapServers: [배포 이름]-kafka-headless:9092  # 카프카 브로커의 헤드리스 서비스 
        zookeeper: [배포 이름]-zookeeper-headless:2181     # 주키퍼의 헤드리스 서비스 
        kafkaConnect:
        #
        # 이 아래 블록은 kafka_connect.connects 에 등록한 connect 들에 대해 기술
        # 커넥트 타입은 kafka_connect.connects.type 에 해당하는 값 
        #
        - name: [커넥트 타입]
          address: http://[배포 이름]-alpaka-[커넥트 타입]:8083
```

위의 커넥트 설정 예를 대상으로 한다면 다음과 같은 내용이 될 것이다.

```yaml
ui4kafka:
  enabled: true         
  yamlApplicationConfig:  
    kafka:            
      clusters:
      - name: myteste-kafka   # 카프카 클러스터 이름 
        bootstrapServers: myteste-kafka-headless:9092  # 카프카 브로커의 헤드리스 서비스 
        zookeeper: myteste-zookeeper-headless:2181     # 주키퍼의 헤드리스 서비스 
        kafkaConnect:
        # jdbcsrc 커넥트 정보 
        - name: jdbcsrc
          address: http://myteste-alpaka-jdbcsrc:8083
```


UI for Kafka 차트는 [Provectus 의 것](https://github.com/provectus/kafka-ui)을 이용하였으나 Helm 패키지 설치에 문제가 있어 [포크한 것](https://github.com/haje01/kafka-ui) 을 이용하였다. 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values kafka-ui/kafka-ui
```

### 쿠버네티스 대쉬보드 설정 

[쿠버네티스 대쉬보드](https://github.com/kubernetes/dashboard)는 쿠버네티스 클러스터 자체의 모니터링을 위해 사용한다. 설정은 대략적으로 다음과 같은 구조를 가진다. 

```yaml
k8dashboard:
  enabled: true                 # 쿠버네티스 대쉬보드를 이용하는 경우 true
  protocolHttp: true 
  # 서비스 관련 
  service:
    externalPort: 8443
  serviceAccount:
    name: k8dash-admin
  # 간편한 로그인
  extraArgs:                    
    - --token-ttl=86400
    - --enable-skip-login       
    - --enable-insecure-login
```

대개의 경우 기본 값을 이용하면 되기에 다음 처럼 간단히 `enabled` 만 설정한다.

```yaml
k8dashboard:
  enabled: true 
```

쿠버네티스 차트는 [여기](https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard) 에서 찾을 수 있다. 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values kubernetes-dashboard/kubernetes-dashboard 
```

### 프로메테우스 설정

[프로메테우스](https://prometheus.io/) 는 서버 및 서비스 관련 메트릭을 모니터링하는데 사용한다. 설정은 대략적으로 다음과 같은 구조를 가진다. 

```yaml
prometheus:
  enabled: true                  # 프로메테우스를 이용하는 경우 true
  prometheus:
    enabled: true
    # 메트릭 수집 관련 
    additionalScrapeConfigs:
      enabled: true
      type: internal
      internal:
        jobList:
        - job_name: [잡 이름]
          scrape_interval: 10s   # 메트릭 수집 주기
          scrape_timeout:  5s    # 메트릭 수집 타임아웃
          metrics_path: "/metrics"
          static_configs:
          - targets:
            - # 메트릭 익스포터의 엔드포인트
```

프로메테우스는 서버에서 메트릭을 프로메테우스로 보내지 않고, 서버에 설치된 익스포터에 프로메테우스가 들어가 메트릭을 가져오는 방식이다. 따라서 이를 위한 익스포터 서비스의 엔드포인트가 필요하다.

> 프로메테우스는 메트릭 수집 및 모니터링의 표준처럼 사용되기에, 대부분 서비스별 Helm 차트에서 프로메테우스용 익스포터를 함께 설정할 수 있도록 지원하고 있다.

뒤에서 설명할 KMinion 및 주키퍼 관련 메트릭을 포함하면 다음과 같은 내용이 될 것이다.

```yaml
prometheus:
  prometheus:
    additionalScrapeConfigs:
      internal:
        jobList:
        - job_name: kminion-metrics
          static_configs:
          - targets:
            - mytest-kminion:8080
        - job_name: zookeeper
          static_configs:
          - targets:
            - mytest-zookeeper-metrics:9141
```

프로메테우스 차트는 [bitnami 의 kube-prometheus](https://github.com/bitnami/charts/tree/main/bitnami/kube-prometheus) 를 사용한다. 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values bitnami/kube-prometheus
```

### 그라파나 설정 

[그라파나](https://grafana.com/)는 프로메테우스가 수집한 메트릭을 시각화할 수 있는 도구이다. 설정은 대략 다음과 같은 구조를 가진다.

```yaml
# 그라파나 설정
grafana:
  enabled: true              # 그라파나를 이용하는 경우 true
  adminSecretName: [배포 이름]-grafana-admin
  admin:
    user: [관리자 ID]
    password: [관리자 암호]
  datasources:
    secretDefinition:
      apiVersion: 1
      # 사용할 데이터 소스 
      datasources:
        # 알파카로 설치한 프로메테우스를 데이터 소스로 이용 
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://[배포 이름]-prometheus-prometheus:9090
          isDefault: true   # 기본 데이터 소스 여부
  dashboardsProvider:
    enabled: true
  # 대쉬보드 설정 파일들 
  dashboardsConfigMaps:
    - configMapName: [배포 이름]-alpaka-grafana-cluster
      fileName: kminion-cluster_rev1.json          # KMinion 카프카 클러스터 대쉬보드 
    - configMapName: [배포 이름]-alpaka-grafana-topic
      fileName: kminion-topic_rev1.json            # KMinion 카프카 토픽 대쉬보드 
    - configMapName: [배포 이름]-alpaka-grafana-groups
      fileName: kminion-groups_rev1.json           # KMinion 카프카 컨슈머 그룹 대쉬보드 
    - configMapName: [배포 이름]-alpaka-grafana-zookeeper
      fileName: zookeeper-by-prometheus_rev4.json  # 주키퍼 대쉬보드 
    - configMapName: [배포 이름]-alpaka-grafana-jvm
      fileName: altassian-overview_rev1.json       # 카프카 브로커의 JMX 대쉬보드 
```

예제의 경우 다음과 같은 내용이 될 것이다.

```yaml
grafana:
  datasources:
    secretDefinition:
      apiVersion: 1
      datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://mytest-prometheus-prometheus:9090
        isDefault: true
  dashboardsConfigMaps:
    - configMapName: mytest-alpaka-grafana-cluster
      fileName: kminion-cluster_rev1.json
    - configMapName: mytest-alpaka-grafana-topic
      fileName: kminion-topic_rev1.json
    - configMapName: mytest-alpaka-grafana-groups
      fileName: kminion-groups_rev1.json
    - configMapName: mytest-alpaka-grafana-zookeeper
      fileName: zookeeper-by-prometheus_rev4.json
    - configMapName: mytest-alpaka-grafana-jvm
      fileName: altassian-overview_rev1.json
```

그라파나 차트는 [bitnami 의 grafana](https://github.com/bitnami/charts/tree/main/bitnami/kube-prometheus) 를 사용한다. 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values bitnami/grafana
```

### 그라파나 용 KMinion 대쉬보드 설정 

[KMinion](https://github.com/redpanda-data/kminion) 은 카프카 클러스터를 모니터링 하기 위한 프로메테우스 익스포터 + 그라파나 대쉬보드를 제공한다. 설정은 대략 다음과 같은 구조를 가진다.

```yaml
kminion:
  enabled: true         # KMinion을 이용하는 경우 true
  kminion:
    config:
      # 카프카 브로커 정보 
      kafka:
        brokers: ["[배포 이름]-kafka-headless:9092"]

    # 익스포터 서비스 정보 
    exporter:
      host: "[배포 이름]-kminion"
      port: 8080
```

예제의 경우 다음과 같은 내용이 될 것이다.

```
kminion:
  kminion:
    config:
      kafka:
        brokers: ["mytest-kafka-headless:9092"]
    exporter:
      host: "mytest-kminion"
```

KMnion 차트는 [여기](https://github.com/redpanda-data/kminion/tree/master/charts) 에서 확인할 수 있다. 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values kminion/kminion
```

### 공용 인그레스 설정

외부 차트의 경우 대부분 자체 인그레스 설정을 지원하기에, 서비스별로 인그레스를 설정할 수도 있다. 그것이 아니면 공용 인그레스를 하나 만들어서 사용할 수 있다. 

쿠버네티스 배포판 중 minikube, k3s, k3d 는 공용 인그레스를 이용하고, AWS EKS 는 서비스별 인그레스를 설정하여 이용한다. 

> 실제 도메인을 사용한다면 둘 다 공용 인그레스 하나를 설정하고 호스트 이름 기반으로 서비스를 구분할 수 있을 것이다. 그렇지 않은 경우 `/etc/hosts` 같은 호스트 파일에 도메인 이름을 기재하여 사용해야 하는데, AWS EKS 는 이것이 불가능하기에 서비스별로 인그레스를 설정하면서 접속 포트를 다르게 하여 구분하는 식으로 이용한다. 

설정은 대략 다음과 같은 구조를 가진다.

```yaml
ingress:
  enabled: true               # 공용 인그레스를 이용하는 경우 true
  annotations:
    # # minikube 설치용
    # kubernetes.io/ingress.class: nginx
    # nginx.ingress.kubernetes.io/rewrite-target: /

    # # K3S (K3D) 설치용
    # kubernetes.io/ingress.class: traefik

    # # AWS EKS 설치용
    # kubernetes.io/ingress.class: alb
    # alb.ingress.kubernetes.io/group.name: public
    # alb.ingress.kubernetes.io/scheme: internet-facing
    # alb.ingress.kubernetes.io/target-type: ip
    # alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 9090}]'
```

주석에서 알 수 있듯이, 쿠버네티스 배포판별로 `annotations` 블럭의 내용이 다른 것에 주의하자. 예제의 경우 다음과 같은 내용이 될 것이다.

```
ingress:
  annotations:
    kubernetes.io/ingress.class: nginx
```

### 설치 후 초기화 설정

알파카를 구성하는 모든 리소스가 만들어진 후에 몇 가지 초기화 작업을 진행해야 하는 경우가 있다. 초기화 설정에서 그런 작업을 위한 스크립트 파일을 정의하고 실행 순서를 지정할 수 있다.

```yaml
init: 
  enabled: false      # 설치 후 초기화를 이용하는 경우 true
  # 초기화가 실행될 컨테이너 정보
  container:
    image: "haje01/alpaka-tool"
    tag: 0.0.2
    pullPolicy: IfNotPresent
  # 초기화에 필요한 스크립트 파일 정의
  files:
    - [쉘스크립트 이름].sh |
      [쉘스크립트 내용] 
  # 초기화 명령어 리스트 (순서대로 실행)
  commands: 
    - [쉘스크립트 이름].sh
```

아래는 DB 를 초기화하는 예이다. 

```yaml
init:
  enabled: true
  files:
  - init_database.sh: |
    echo "> run 'init_database.sh'"
    mysql -u myuser -e "CREATE DATABASE test"
  commands:
  - init_database.sh
```

### 설치 후 테스트 설정 

알파카는 설치 후 잘 동작하는지 확인을 위해 기본적인 테스트 코드를 제공한다. 이 코드는 툴 컨테이너 이미지에 포함되어 있다. 설정은 대략 다음과 같은 구조를 가진다.

```yaml
test:
  enabled: true     # 설치 후 테스트를 진행하는 경우 true
  # 테스트용 컨테이너 정보 
  container:
    image: "haje01/alpaka-tool"
    tag: 0.0.2
    pullPolicy: IfNotPresent
```

테스트는 설치 후 자동으로 진행된다. 만약 테스트를 원하지 않으면 아래와 같이 설정파일에 기술한다.

```json
test:
  enabled: false
```

## 설치, 활용, 삭제

### 설치 

설정 파일이 완료되었으면 그것으로 설치를 진행한다. 설치는 저장소에서 바로 설치하는 방법과 로컬에 있는 alpaka 코드에서 설치하는 두 가지 방법으로 나뉜다.

#### 저장소에서 바로 설치하기

먼저 설치된 Helm 에 alpaka 저장소 등록이 필요하다. 알파카는 별도 차트 저장소 없이 GitHub 저장소의 패키지 파일을 이용한다. 다음과 같이 등록하자.

```bash
helm repo add alpaka https://raw.githubusercontent.com/haje01/alpaka/master/chartrepo
```

다음처럼 등록 결과를 확인할 수 있다.

```bash
$ helm search repo alpaka
NAME            CHART VERSION   APP VERSION     DESCRIPTION
alpaka/alpaka   0.0.2           3.3.1           Yet another Kafka deployment chart.
```

이제 다음과 같이 저장소에서 설치할 수 있다 (설정 파일은 미리 준비되어야 한다).

```bash
# minikube 의 경우 
helm install -f configs/_mkb.yaml mkb alpaka/alpaka 

# k3s 의 경우 
helm install -f configs/_k3s.yaml k3s alpaka/alpaka 

# eks 의 경우 
helm install -f configs/_eks.yaml eks alpaka/alpaka 
```

여기서는 설명을 위해 배포판 샘플 설정 파일을 그대로 이용했지만, 실제로는 샘플 파일을 복사하여 업무 환경에 맞는 자신만의 설정 파일을 만들어 쓰는 것이 맞겠다.

> 편의상 설정 파일명과 배포 이름을 같게 하였다. 실제로는 필요에 따라 배포 이름을 다르게 줄 수 있다.

`alpaka/alpaka` 는 `저장소/차트명` 이다. 버전을 명시하여 설치할 수도 있다.

```bash
helm install -f configs/_k3s.yaml k3s alpaka/alpaka --version 0.0.2
```

#### 로컬 코드에서 설치하기

Git 을 통해 내려받은 코드를 이용해 설치할 수 있다 (이후 설명은 내려받은 코드의 디렉토리 기준). yaml 파일을 수정하면서 테스트할 때는 코드에서 설치하는 것이 편할 것이다.

먼저 의존 패키지를 등록하는 과정이 필요하다.  차트 정보가 있는 `alpaka/alpaka/` 디렉토리로 이동 후 다음처럼 수행한다.

```bash
helm dependency update
```

> 다음 차트들은 버그가 있어 패치된 것을 이용한다.
>
> - `kminion` - `policy/v1beta` 의 호환성 문제
> - `bitnami/kube-prometheus` - Ingress 에서 `hostname` 에 `*` 를 주면 [에러 발생](https://github.com/bitnami/charts/issues/14070)
> - `provectus/kafka-ui` - 차트 저장소가 사라짐

다시 상위 디렉토리로 이동 후, 다음과 같이 로컬 코드에서 설치할 수 있다.

```bash
# minikube 의 경우
helm install -f configs/_mkb.yaml mkb alpaka/

# k3s 의 경우
helm install -f configs/_k3s.yaml_ k3s alpaka/

# eks 의 경우
helm install -f configs/_eks.yaml eks alpaka/
```

`alpaka/` 는 차트가 있는 디렉토리 명이다.

### 설치 후 활용

#### 테스트

알파카가 잘 설치되었는지 확인하기 위해 기본적인 테스트가 제공되는데, 이를 위해 테스트를 위한 잡, 파드 및 MySQL DB 서비스가 설치되게 된다.

`[배포 이름]-alpaka-test-[임의 문자열]` 형식의 파드가 테스트를 위한 것으로, 이것은 [배포 이름]-alpaka-test` 형식의 Job 을 통해 시작된 것이다. 만약 테스트가 실패하면 다음과 같이 실패 메시지를 확인하여 문제를 파악할 수 있다.

```
kubectl logs job/[배포 이름]-alpaka-test
```

테스트는 설치 후 자동으로 실행된다. 만약 테스트를 원하지 않으면 아래와 같이 설정파일에 기술한다.
```json
test:
  enabled: false
```

이미 설치 및 수행된 테스트 관련 리소스를 제거하려면, 설정파일에 위와 같이 기술 후 Helm 업그레이드를 하면 된다.

```
helm upgrade -f configs/_mkb.yaml mkb alpaka
```

테스트 관련 리소스가 제거된 것을 확인할 수 있을 것이다.

#### 설치 노트

설치가 성공하면 노트가 출력되는데 이를 활용에 참고하도록 하자. 아래는 `wsl_mkb.yaml` 설정 파일을 이용해 단일 노드에 설치한 경우의 노트이다.

> `helm status wslmkb` 명령으로 다시 볼 수 있다.

```markdown
NAME: mkb
LAST DEPLOYED: Tue Jan 17 14:01:05 2023
NAMESPACE: default
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
# 설치된 파드 리스트

  kubectl get pods --namespace default -l app.kubernetes.io/instance=mkb

# 카프카 브로커 호스트명

  mkb-kafka

  Ingress (AWS ALB) 주소:
  export ING_URL=$(k get ingress | sed -n 2p | awk '{print $4}')

# 알파카 Tool 에 접속

  export ATOOL_POD=$(kubectl get pods -n default -l "app.kubernetes.io/instance=mkb,app.kubernetes.io/component=alpaka-tool" -o jsonpath="{.items[0].metadata.name}")
  kubectl exec -it $ATOOL_POD -n default -- bash

# 쿠버네티스 대쉬보드

  접속 URL:
  echo "$ING_URL:8443"


# 카프카 UI
  접속 URL:
  echo "$ING_URL:8989"

# 프로메테우스

프로메테우스 접속:
    접속 URL:
    echo "$ING_URL:9090"

얼러트매니저 접속:
    접속 URL:
    echo "$ING_URL:9093"

# 그라파나
  접속 URL:
  echo "$ING_URL:3000"

  유저: admin
  암호: admindjemals (admin어드민)


# 테스트용 MySQL

root 사용자 암호

  MYSQL_ROOT_PASSWORD=$(kubectl get secret --namespace default mkb-mysql -o jsonpath="{.data.mysql-root-password}" | base64 -d)

# 테스트 로그 확인

  kubectl logs job/test
```

#### 웹 접속하기 

알파카를 통해 설치된 서비스의 웹페이지 접속을 위해서는 인그레스가 필요한데, AWS EKS 를 제외한 다른 쿠버네티스 배포판에서는 공용 인그레스를 만들어 이용한다. 설정 파일의 `annotations` 요소에 쿠버네티스 배포판 별로 커스텀한 인그레스 설정이 들어가는 것에 주의하자. 공용 인그레스가 필요없는 경우 `ingress.enabled` 를 `false` 로 하자. 

> 윈도우 WSL (Windows Subsystem for Linux) 환경에서 minikube 를 이용하는 경우, 아래와 같이 터널링해주어야 인그레스를 외부에서 접근할 수 있다.
>
> `minikube tunnel`
> 
> 이후 호스트 파일 `C:\Windows\System32\drivers\etc\hosts` 에서 아래와 같이 추가해주면 ([참고](https://www.liquidweb.com/kb/edit-host-file-windows-10/)) 윈도우상의 웹브라우저에서 도메인 이름으로 접속이 가능하다.
> 127.0.0.1  grafana.alpaka.wai
> 127.0.0.1  k8dashboard.alpaka.wai
> 127.0.0.1  ui4kafka.alpaka.wai
> 127.0.0.1  prometheus.alpaka.wai
>

AWS EKS 에 설치한 경우는 다음과 같이 접속 주소를 확인할 수 있다.

```
$ kubectl get ingress

NAME                        CLASS    HOSTS   ADDRESS                                                            PORTS   AGE
eks-grafana                 <none>   *       k8s-public-1946ec9e92-277402474.ap-northeast-2.elb.amazonaws.com   80      16m
eks-k8dashboard             <none>   *       k8s-public-1946ec9e92-277402474.ap-northeast-2.elb.amazonaws.com   80      16m
eks-prometheus-prometheus   <none>   *       k8s-public-1946ec9e92-277402474.ap-northeast-2.elb.amazonaws.com   80      16m
eks-ui4kafka                <none>   *       k8s-public-1946ec9e92-277402474.ap-northeast-2.elb.amazonaws.com   80      16m
```

EKS 의 인그레스는 는 ALB 를 이용하는데, 여기서는 도메인 없이 사용하기에 위의 경우 `k8s-public-1946ec9e92-2144952281.ap-northeast-2.elb.amazonaws.com` 주소로 접속하면 되겠다. 서비스 별로 접속 포트가 다른데, 아래를 참고하자. 

- Kubernetes Dashboard : `8443`
- UI for Kafka : `8080`
- Grafana : `3000`
- Prometheus : `9090`

예를 들의 위 예에서는 `k8s-public-1946ec9e92-277402474.ap-northeast-2.elb.amazonaws.com:3000` 주소로 그라파나에 접속할 수 있다.

> `Ingress` 는 원래 `80 (HTTP)` 및 `443 (HTTPS)` 포트로 접근이 제한된다. 위 예처럼 포트를 달리하여 다양한 서비스에 접속하는 방식은 AWS ALB 에 특화된 팁으로 볼 수 있다.
> 보다 정통적인 방법은 서브 도메인을 이용하는 것이다.

### 삭제 

아래와 같이 삭제할 수 있다.
```bash
# minikube 의 경우
helm uninstal mkb

# k3s 의 경우
helm uninstal k3s

# eks 의 경우
helm uninstal eks

```

중요한 점은 설치시 생성된 PVC 는 삭제되지 않는 것이다. 이는 중요한 데이터 파일을 실수로 삭제하지 않기 위함으로, 필요없는 것이 확실하다면 아래처럼 삭제해 주자.

```bash
kubectl delete pvc --all
```

## 기타

### 초기화 명령 

카프카 클러스터 생성이 완료된 후 추가적으로 초기화에 필요한 명령이 있을 수 있다. 이를 위해 설정 파일의 `init` 블럭에서 초기화 스크립트를 등록하고 실행할 수 있다. 아래는 데이터베이스 초기화의 예이다.

```yaml
init:
  enabled: true
  files:
    init_database.sh: |
      echo "> run 'init_database.sh'"
      mysql -u myuser -e "CREATE DATABASE test"
  commands:
    - init_database.sh
```

`files` 섹션에 초기화에 필요한 파일의 구현을 기술하고, 그 아래 `commands` 에서 지정한 순서대로 그 파일들을 실행하여 초기화를 진행하게 된다.

### alpaka 레포지토리 갱신

알파카의 내용 및 관련 패키지 수정이 필요한 경우 `alpaka/Chart.yaml` 파일의 `version` 또는 `appVersion` 을 필요에 따라 수정하고, 알파카 코드 디렉토리에서 아래와 같이 패키지를 생성한다. 

```bash
helm package alpaka/
```

그러면 `alpaka-0.0.2.tgz` 와 같은 패키지 파일이 생성되는데, 이것을 `chartrepo` 디렉토리로 옮긴 후, `chartrepo` 디렉토리에서 인덱스 파일을 생성한다 (하나 이상의 패키지 파일이 있어도 괜찮다).

```bash
helm repo index .
```
이제 `chartrepo/` 디렉토리에 패키지 및 인덱스 파일이 존재하는지 확인 후 커밋하면 된다.
