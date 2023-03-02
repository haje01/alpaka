# alpaka

[카프카](https://kafka.apache.org/)는 분산형 데이터 스트리밍 플랫폼으로 비교적 설정이 복잡하고 함께 사용하는 서비스도 다양해 설치가 좀 까다롭다. 알파카는 Kubernetes 클러스터에 Kafka 및 관련 패키지를 쉽게 배포하기 위한 Helm 차트이다 (차트는 설치 패키지와 비슷한 개념으로 여기서는 혼용하겠다). 다음과 같은 외부 패키지를 포함한다:

- Kafka
- Zookeeper
- Kafka 용 JDBC 커넥터
- ksqlDB
- UI for Kafka
- Prometheus (+ KMinion)
- Grafana (+ 각종 대쉬보드)
- Loki 
- Kubernetes Dashboard

추가적으로 테스트 및 운영에 필요한 툴 컨테이너가 설치된다.

## 사전 준비

OS 별로 도커를 사용할 수 있도록 준비하고, 여기에 추가적으로 [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) 과 [Helm](https://helm.sh/docs/intro/install/) 가 설치되어 있어야 한다. 각각의 링크를 참고하여 진행하자.

다음으로 사용할 쿠버네티스 배포판을 선택해야 한다. 개발용으로는 로컬 쿠버네티스 배포판을, 프로덕션 용도로는 클라우드 또는 IDC 용 배포판을 이용할 수 있다. 알파카는 로컬용으로 [minikube](https://minikube.sigs.k8s.io/docs/), [k3s](https://k3s.io/) 및 [k3d](https://k3d.io/v5.4.6/) 를, 프로덕션용으로 [AWS EKS](https://aws.amazon.com/ko/eks/) 을 위한 설정 파일을 기본으로 제공한다. 

다른 배포판 환경에도 조금만 응용하면 무리없이 적용할 수 있을 것이다.

### 로컬 쿠버네티스 배포판 관련

로컬 쿠버네티스 환경에서는 메모리가 너무 작으면 파드가 죽을 수 있고, 디스크 용량이 너무 작으면 PVC 할당이 안될 수 있으니 주의하자. 

#### minikube 이용시

코어 4개, 메모리 8GB, 디스크 40GB 예:
```
minikube start --cpus=4 --memory=10g --disk-size=40g
```

#### k3d 이용시 

워커노드 2 대, 노드별 메모리 8GB, Ingress 이용의 예:

```
K3D_FIX_DNS=1 k3d cluster create -p "80:80@loadbalancer" --agents 2 --agents-memory=8gb
```

> K3D_FIX_DNS 가 없으면 생성된 클러스터내 파드에서 인터넷 접속 안되는 문제가 있다.
> ( https://github.com/k3d-io/k3d/issues/209 )


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

외부 패키지를 이용할 때는 그쪽에서 공개한 공식 컨테이너 이미지를 이용하면 된다. 추가적으로 알파카가 사용하는 부속 컨테이너 이미지는 직접 만들어 주어야 할 경우가 있기에 여기서 소개한다. 현재 이미지는 툴 및 DB 커넥터용의 두 가지가 있다.

#### 툴 컨테이너 이미지

서비스를 위한 컨테이너 이미지는 용량, 속도, 보안 등의 이슈로 대부분 서비스에 꼭 필요한 실행 파일만 설치되어 있다. 그런데 패키지를 설치하고 운용하다 보면 여러가지 문제가 발생하기에, 이를 찾고 고치기 위한 실행파일이 설치된 이미지가 있으면 편리하다. 알파카에서는 이것을 툴 컨테이너 이미지라고 부른다. 

여기에는 vim, kcat, jq, 파이썬 및 DNS 유틸 등이 설치되어 있기에, 클러스터 내 다른 컨테이너의 동작을 확인하거나 네트워크 이슈를 찾는 등 다양한 작업을 할 수 있다. 기본 툴 이미지는 도커 허브의 [haje01/alpaka-tool](https://hub.docker.com/repository/docker/haje01/alpaka-tool/general) 로 올라가 있기에 이것을 사용하면 된다. 


> 만약 독자적인 툴 이미지가 필요하면 `images/Dockerfile.tool` 및 `images/build_tool.sh` 파일을 참고하여 만들도록 하자.

#### DB 커넥트 이미지 

카프카의 커넥터 (Connector) 는 다양한 데이터 소스에서 데이터를 가져오거나, 외부로 내보내는 데 사용되는 일종의 플러그인이다. 커넥터는 카프카 커넥트 (Connect) 장비에 등록되어 동작하는데, 알파카에서는 기본적으로 [Confluent JDBC 커넥터](https://docs.confluent.io/kafka-connectors/jdbc/current/index.html) 및 [Debezium](https://debezium.io/) 이 설치된 DB 용 커넥트 이미지를 제공한다.


기본 DB 커넥트 이미지는 도커 허브의 [haje01/kafka-srccon](https://hub.docker.com/repository/docker/haje01/kafka-srccon/general) 으로 올라가 있기에 이것을 사용하면 된다. 

> 만약 독자적인 DB 커넥터 이미지가 필요하면 `images/Dockerfile.srccon` 및 `images/build_srccon.sh` 파일을 참고하여 만들도록 하자.


## 설정 파일 만들기 

설치를 위해서는 먼저 설정 파일이 필요하다. `configs/` 디렉토리에 아래와 같은 샘플 설정 파일이 있으니 참고하여 자신의 필요에 맞는 설정 파일을 만들어 사용한다 (샘플 설정 파일은 구분하기 쉽게 `_` 로 시작한다):
- `_mkb.yaml` - minikube 용
- `_k3s.yaml` - k3s 용
- `_k3d.yaml` - k3d 용
- `_eks.yaml_` - eks 용

> 여기서는 참고용으로 쿠버네티스 배포판별 설정 파일을 만들었지만 꼭 이렇게 할 필요는 없다. 실제로는 한 번 선택한 쿠버네티스 배포판 자주 바뀌지 않기에 개발/테스트/라이브 등의 용도별로 설정 파일을 만드는 것이 더 적합할 것이다.

> `alpaka/values.yaml` 는 차트에서 사용하는 기본 변수값을 담고 있다. 위의 파일들과 함께 참고하여 커스텀 설정 파일을 만들 수 있겠다.

설정 파일은 [YAML](https://yaml.org/) 형식의 파일로, 최상위 블럭만 표시하면 다음과 같은 구조를 가진다.

```yaml
k8s_dist:       # 쿠버네티스 배포판 종류 (minikube, k3s, k3d, eks 중 하나)

kafka:          # 카프카 설정 

kafka_connect:  # 카프카 커넥트 및 커넥터 설정 

ui4kafka:       # UI for Kafka 설정

k8dashboard:    # 쿠버네티스 대쉬보드 설정 

prometheus:     # 프로메테우스 설정

grafana:        # 그라파나 설정 

loki:           # 그라파나 로키 설정

kminion:        # 그라파나 용 KMinion 대쉬보드 설정 

ingress:        # 공용 인그레스 설정

init:           # 클러스터 설치 후 초기화 설정 

test:           # 클러스터 설치 후 테스트 설정 
```

`k8s_dist`, `kminion`, `ingress`, `kafka_connect`, `init` 그리고 `test` 는 알파카 자체적인 설정 블럭이다. `kafka`, `ui4kafka`, `k8dashboard`, `prometheus`, `grafana` 는 알파카가 의존하는 외부 패키지를 위한 설정 블럭이다.

지금부터는 테스트를 위한 간단한 설정 파일을 만들어 가면서 설정 파일 작성 방법을 소개하겠다. 이 설정 파일은 로컬에서 minikube 배포판을 이용하고, 설정 파일은 `configs/_mkb.yaml` 샘플을 참고하여 `configs/mymkb.yaml` 에 저장하는 것으로 가정하겠다. 파일의 최초 내용은 아래와 같다.

```yaml
k8s_dist: minikube
```

이 설정 파일이 완성되면 다음과 같이 설치하게 될 것이다.

```
helm install -f configs/mymkb.yaml my alpaka/
```

이 경우 배포 이름은 `my` 이 된다. 

이제 각 설정 블럭을 차례대로 설명하겠다. 알파카 차트나 알파카 변수 파일 `alpaka/values.yaml` 에 기본값이 지정되어 있고 설정 파일에 관련 내용이 없으면 기본값이 이용된다.

### 카프카 설정 

카프카 클러스터 및 주키퍼 관련 내용을 여기서 설정한다. 대략의 구조는 아래와 같다.

```yaml
kafka: 
  replicaCount: 1              # 카프카 브로커의 수. HA 구성을 위해서는 3 을 추천 
  defaultReplicationFactor: 1  # 토픽 복제 수. 브로커 수가 3 인 경우 2 를 추천 
  numPartitions: 8             # 토픽별 파티션 수
```

기본 값은 브로커 1 대, 파티션 수 8 개로 이대로 사용하고자 하면 별도의 `kafka` 블럭을 지정하지 않아도 카프카 클러스터가 만들어진다.

카프카는 [bitnami 의 kafka Helm 차트](https://bitnami.com/stack/kafka/helm) 를 이용하였다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values bitnami/kafka
```

### 카프카 커넥트 설정 

카프카 커넥터는 데이터를 카프카로 가져오거나 외부로 내보내기 위한 일종의 플러그인이다. 커넥트는 커넥터를 기동하기 위한 장비로 생각하면 간단하다.

커넥트 설정은 꽤 복잡한데 대략적인 구조를 표시하면 아래와 같다.

```yaml
kafka_connect:
  # 커넥트 리스트
  connects:
    # 개별 커넥트 정보 
    - type:    # 커넥트 타입
      values:  # 커넥트 내에서 공유되는 변수값
    # 커넥터 그룹 리스트 
    connector_groups:
      # 개별 커넥터 그룹 정보 
      - name:    # 커넥터 그룹 이름 
        values:  # 커넥터 그룹 내에서 공유되는 변수값
        common:  # 커넥터 그룹 내 공통 설정
        # 개별 커넥터 리스트 
        connectors:  
          - name:    # 커넥터 이름
            config:  # 커넥터 개별 설정 
```

최초로 `connect` 블록 아래에 하나 이상의 커넥트 정보를 기술할 수 있다. 커넥트는 같은 커넥터 라이브러리를 사용하는 서비스를 하나 이상 기동하기 위한 장비의 구분 정도로 생각하자. 

각 커넥트에는 `values` 블럭이 나올 수 있는데, 커넥터 내에서 공유되는 변수를 기술하는데 사용된다.

커넥터는 크게 비슷한 설정을 가지는 것들끼리 그룹지을 수 있는데, 이것을 위해 `connector_groups` 블럭이 존재하며 그 아래 커넥터 그룹 리스트가 나온다.

각 커넥터 그룹에는 `values` 와 `common` 블럭이 있는데, 각각 커넥터 그룹 내에서 공유되는 변수 및 공통 설정을 기술하는 데 사용된다.

아래는 DB 에서 데이터를 가져오기 위한 JDCB 소스 커넥트를 위한 구체적인 예로, 여기서는 MySQL 에 있는 `mydb` 라는 DB 에서 로그성 테이블 `log1` 과 `log2` 그리고 코드성 테이블 `code` 를 가져오는 경우를 가정하였다.

> 이 예는 어디까지나 설명을 위한 것으로 실제 커넥터 설정은 좀 더 상세한 설정이 필요하다.

```yaml
kafka_connect:
  enabled: true       # 커넥트를 사용하면 true.
  # 커넥트 정보
  connects:           # 이 블록아래 커넥트를 종류별로 기술 
  - type: srccon        # 커넥트 타입 정보. 여기서는 JDBC 소스 커넥터 타입 
    replicaCount: 1      # 커넥트 파드 수
    # 컨테이너 정보 
    container:                     
      image: "haje01/kafka-srccon"   # 컨테이너 이미지 
      tag: 0.0.5                     # 이미지 태그 
      pullPolicy: IfNotPresent       # 이지미 풀 정책 
    timezone: Asia/Seoul # 커넥트 파드의 타임존 
    # 커넥트 레벨에서 공유될 변수 값 리스트 
    values:                    
      db_host: mysql-db-addr      # DBMS 호스트 주소
      db_port: 3306               # DBMS 접속 포트
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
        connection.url: "jdbc:mysql://{{ .Values.db_host }}:{{ .Values.db_port }};databaseName={{ .Values.db_name }}" # 커넥터 접속 URL
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
          connection.url: "jdbc:mysql://{{ .Values.db_host }}:{{ .Values.db_port }};databaseName={{ .Values.db_name }}" # 커넥터 접속 URL
          connection.password: "{{ .Values.db_pass }}"  # DB 유저 암호
          mode: "bulk"        # 소스 커넥터의 동작 모드 
          topic.prefix: code  # 카프카 토픽 접두사 
          query: |            # 데이터를 가져올 쿼리문
            SELECT 
              CURRENT_TIMESTAMP() AS regtime,
              code, desc
            FROM code
```

갑자기 너무 많은 설정이 나와 당황스러울 것이나, 앞서 설명한 구조를 바탕으로 천천히 살펴보면 이해가 될 것이다.

`common` 및 `config` 에 기술된 각 커넥터 설정은 일종의 텍스트 템플릿이다. 텍스트내에 `{{ .Values.~ }}` 형식으로 기술하면 관련 변수가 앞선 `values` 에 있는 경우 대체된다. `{{ }}` 을 포함하지 않는 일반 텍스트는 그대로 커넥터 설정으로 사용된다.

커넥트 레벨, 커넥트 그룹 레벨의 `values` 블럭에서 기술된 변수는 결합되어 사용되며, 이때 중복된 변수 값이 있으면 가까운 값을 이용하게 된다. 예를 들어 다음과 같이 변수의 값이 지정되어 있다면 :

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

`connector1` 의 최종 설정에서 `A_is: 2`, `B_is: 1` 과 같게 된다. 

커넥터의 설정 값도 커넥터 그룹의 `common` 블럭 및 개별 커넥터의 `config` 블럭의 값이 같은 방식으로 결합되어 사용된다.

최종 결과물은 각 커넥터 별로 등록 가능한 쉘 스크립트 형식으로 저장되는데, 그것은 `[커넥트 타입]-[커넥터 그룹]-[커넥터 이름].sh` 형식 이름의 실행가능한 파일로 뒤에서 설명할 **초기화 파드** 에 저장된다. 

위 설정 예제의 경우 초기화 파드 `/usr/local/bin` 디렉토리 아래 다음과 같은 세가지 파일이 생성된다.

```
srccon-mydb_log-log1.sh
srccon-mydb_log-log2.sh
srccon-mydb_code-code.sh
```

각 파일의 내용은 다음과 같다. 

`srccon-mydb_log-log1.sh`
```
curl -s -X POST http://my-alpaka-srccon:8083/connectors -H "Content-Type: application/json" -d '{
    "name": "srccon-mydb_log-log1.sh",
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

`srccon-mydb_log-log2.sh`
```
curl -s -X POST http://my-alpaka-srccon:8083/connectors -H "Content-Type: application/json" -d '{
    "name": "srccon-mydb_log-log2.sh",
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

`srccon-mydb_code-code.sh`
```
curl -s -X POST http://my-alpaka-srccon:8083/connectors -H "Content-Type: application/json" -d '{
    "name": "srccon-mydb_code-code.sh",
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

잘 살펴보면 앞서 기술한 설정 및 변수값이 적용되어 있는 것을 알 수 있을 것이다. 이 파일이 실행되면 `curl` 을 통해 카프카 커넥트의 API 를 호출하여 각 커넥터를 등록하하게 된다.

> `test.enabled` 가 `true` 인 때에는 커넥터 등록 스크립트가 생성되지 않음에 주의하자. 

### 커넥터 등록과 갱신 

위에서 생성된 커넥터 등록 스크립트는 설치 완료 후 명시적으로 호출이 되어야 한다. 이를 위해서는 아래에서 설명할 **설치 후 초기화 설정** 을 이용하여야 하는데, 여기서 간단히 보여주면 아래와 같은 식이다.

```yaml
init:
  commands:
  - srccon-mydb_log-log1.sh
  - srccon-mydb_log-log2.sh
  - srccon-mydb_code-code.sh
```

그런데, 매번 이렇게 등록 스크립트를 기술해 주는 것은 불편하고 틀리기도 쉽다. 이에 모든 커넥터 등록 스크립트를 실행해주는 스크립트가 자동으로 생성되니 아래와 같이 이것을 이용하면 편리하다. 

```yaml
init:
  commands:
  - test-alpaka-srccon-all.sh
```

> `test.enabled` 가 `true` 인 경우 이 모든 커넥터 등록 스크립트가 생성되지 않으니 호출하지 않도록 하자.

이 스크립트의 파일명은 `[배포 이름]-alpaka-[커넥트 타입]-all.sh` 형식이다. 위 경우 `test` 배포에서 `srccon` 커넥트 아래에 만들어진 모든 등록 쉘스크립트가 이 안에 리스팅되어 실행되게 된다.

한 번 등록된 커넥터는 운영을 하면서 필요에 따라 설정을 바꿔야하는 경우도 빈번한데, 이 경우 지금까지 처럼 설정 파일에서 커넥터 설정을 바꿔주고 아래와 같이 Helm 의 업그레이드를 이용하면 적용된다.

```
helm upgrade -f configs/mymkb.yaml test alpaka/
```

일반적으로는 이렇게 하면 **설정파일 변경 -> ConfigMap 재생성 -> 관련 쿠버네티스 리소스 재생성** 식으로 진행되는데, 수정하지 않은 커넥트까지 불필요한 재시작을 겪게된다. 이에 알파카는 업그레이드시 사용된 커넥터 설정을 기 등록된 커넥터 설정과 비교하여 변경된 커넥터만 삭제 후 다시 등록하도록 구현되어 있다. 

### ksqlDB 설정 

[ksqlDB](https://ksqldb.io/) 는 SQL 형식 명령을 통해 카프카의 정보를 스트리밍 방식으로 처리하거나 질의할 수 있게 해준다. 일반적으로 다음과 같은 구성이다.

```yaml
ksqldb:
  enabled: false
  ksqldb:
    nameOverride: RELEASE-ksqldb
    kafka:
      # ksqlDB 차트에서 제공하는 카프카 사용 여부. 
      enabled: false 
      bootstrapServer: PLAINTEXT://RELEASE-kafka-headless:9092
    schema-registry: 
      # ksqlDB 차트에서 제공하는 스키마 레지스트리 사용 여부. 
      enabled: false 
    kafka-connect:
      # ksqlDB 차트에서 제공하는 커넥터 사용 여부. 
      enabled: false 
```

기본적으로 꺼져있는데, 지금가지 예제를 기준으로 사용하도록 설정한다면 다음과 같이 될 것이다.

```yaml
ksqldb:
  enabled: true 
  ksqldb:
    nameOverride: my-ksqldb
    kafka:
      enabled: false 
      bootstrapServer: PLAINTEXT://my-kafka-headless:9092  
```

ksqlDB 차트는 [여기](https://ricardo-aires.github.io/helm-charts/charts/ksqldb/) 에서 확인할 수 있다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values rhcharts/ksqldb
```

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
      - name: my-kafka   # 카프카 클러스터 이름 
        bootstrapServers: my-kafka-headless:9092  # 카프카 브로커의 헤드리스 서비스 
        zookeeper: my-zookeeper-headless:2181     # 주키퍼의 헤드리스 서비스 
        kafkaConnect:
        # srccon 커넥트 정보 
        - name: srccon
          address: http://my-alpaka-srccon:8083
```

> `test.enabled` 가 `true` 인 경우 srccon 커넥트의 주소는 `address: http://my-alpaka-test-srccon:8083` 를 이용해야 한다.

UI for Kafka 차트는 최초에 [Provectus 의 것](https://github.com/provectus/kafka-ui)을 이용하였으나, Helm 패키지 설치에 문제가 있어 [포크한 것](https://github.com/haje01/kafka-ui) 을 이용하였다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

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

쿠버네티스 대쉬보드의 차트는 [여기](https://artifacthub.io/packages/helm/k8s-dashboard/kubernetes-dashboard) 에서 찾을 수 있다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

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
        # 수집 잡 리스트
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

> 프로메테우스는 메트릭 수집 및 모니터링의 표준처럼 사용되기에, 대부분 Helm 차트에서 프로메테우스용 익스포터를 함께 설정할 수 있도록 지원하고 있다.

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
            - my-kminion:8080
        - job_name: zookeeper
          static_configs:
          - targets:
            - my-zookeeper-metrics:9141
```

프로메테우스 차트는 [bitnami 의 kube-prometheus](https://github.com/bitnami/charts/tree/main/bitnami/kube-prometheus) 를 사용한다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

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

그라파나는 기본 설치 후 사용할 대쉬보드를 따로 등록해주어야 하는데, `dashboardsConfigMaps` 블럭 아래에 알파카에서 제공하는 기본 대쉬보드 리스트를 확인할 수 있다. 

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
        url: http://my-prometheus-prometheus:9090
        isDefault: true
  dashboardsConfigMaps:
    - configMapName: my-alpaka-grafana-cluster
      fileName: kminion-cluster_rev1.json
    - configMapName: my-alpaka-grafana-topic
      fileName: kminion-topic_rev1.json
    - configMapName: my-alpaka-grafana-groups
      fileName: kminion-groups_rev1.json
    - configMapName: my-alpaka-grafana-zookeeper
      fileName: zookeeper-by-prometheus_rev4.json
    - configMapName: my-alpaka-grafana-jvm
      fileName: altassian-overview_rev1.json
```

그라파나 차트는 [bitnami 의 grafana](https://github.com/bitnami/charts/tree/main/bitnami/kube-prometheus) 를 사용한다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values bitnami/grafana
```

### 그라파나 용 KMinion 대쉬보드 설정 

[KMinion](https://github.com/redpanda-data/kminion) 은 카프카 클러스터를 모니터링 하기 위한 프로메테우스 익스포터 및 그라파나 대쉬보드를 제공한다. 설정은 대략 다음과 같은 구조를 가진다.

```yaml
kminion:
  enabled: true         # KMinion을 이용하는 경우 true
  kminion:
    config:
      # 카프카 브로커 정보 
      kafka:
        brokers: ["[배포 이름]-kafka-headless:9092"]

    # KMinion 익스포터 서비스 정보 
    exporter:
      host: "[배포 이름]-kminion"
      port: 8080
```

예제의 경우 다음과 같은 내용이 될 것이다.

```yaml
kminion:
  kminion:
    config:
      kafka:
        brokers: ["my-kafka-headless:9092"]
    exporter:
      host: "my-kminion"
```

KMnion 차트는 [여기](https://github.com/redpanda-data/kminion/tree/master/charts) 에서 확인할 수 있다. 로컬 Helm 저장소에 등록하였다면 차트의 기본값은 다음처럼 확인할 수 있다.

```
helm show values kminion/kminion
```

#### 그라파나 로키 설정 

그라파나 로키는 텍스트 로그를 수집/저장하기 위한 툴이다. 알파카에서는 다양한 서비스의 로그를 중앙 집중형으로 관리하기 위해서 로키의 설치를 지원한다 (기본은 꺼져있음). 굳이 로키를 설치하지 않아도 쿠버네티스의 로깅을 이용하여 로그를 확인할 수 있으나, 많은 노드에서 다양한 서비스가 장기간 서비스되는 경우 로키를 설치하면 로그 모니터링이 더 편리할 것이다. 

그라파나 로키는 다양한 컴포넌트를 이용하여 구성되었기에 설정이 꽤 복잡할 수 있다. 일반적으로는 다음과 같이 로그 보유 기간 (Retention) 정도만 지정하여 이용할 수 있다.

```yaml
loki:
  enabled: true
  retention_period: 72h  # 3일간 로그 보관 
```

더 자세한 것은 `alpaka/values.yaml` 및 차트의 변수 파일을 참고하자. 로컬 Helm 저장소에 등록하였다면 차트의 기본값을 다음처럼 확인할 수 있다.

```
helm show values bitnami/grafana-loki
```


### 공용 인그레스 설정

외부 차트의 경우 대부분 자체 인그레스 설정을 지원하기에, 서비스별로 인그레스를 설정할 수 있다. 아니면 공용 인그레스를 하나 만들어서 공유할 수 있다. 

샘플 설정 파일에서는 쿠버네티스 배포판 중 minikube, k3s, k3d 는 공용 인그레스를 이용하고, AWS EKS 는 서비스별 인그레스를 설정하여 이용한다. 

> 실제 도메인을 사용한다면 둘 다 공용 인그레스 하나를 설정하고 호스트 이름 기반으로 서비스를 구분할 수 있을 것이다. 그렇지 않은 경우 `/etc/hosts` 같은 호스트 파일에 도메인 이름을 기재하여 사용해야 하는데, AWS EKS 는 이것이 불가능하기에 서비스별로 인그레스를 설정하면서 접속 포트를 다르게 하여 구분하는 식으로 이용한다. 

공용 인그레스 설정은 대략 다음과 같은 구조를 가진다.

```yaml
ingress:
  enabled: true               # 공용 인그레스를 이용하는 경우 true
  annotations:
    # # minikube 설치용
    # kubernetes.io/ingress.class: nginx

    # # k3s 설치용
    # kubernetes.io/ingress.class: traefik

    # # k3d 설치용
    # ingress.kubernetes.io/ssl-redirect: "false"

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

AWS EKS 를 사용하는 경우 공용 인그레스를 사용하지 않고, Helm 차트별로 제공하는 인그레스 설정에 아래와 같은 어노테이션을 추가하여 사용한다. 

```yasml
  ...

  annotations:
    # AWS EKS 설치용
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/group.name: public
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": [서비스 포트]}]'

  ...
```

자세한 것은 `configs/_eks.yaml` 파일을 참조하자.

### 설치 후 초기화 설정

알파카를 구성하는 모든 리소스가 만들어진 후에 몇 가지 초기화 작업이 필요한 경우가 생길 수 있다. 초기화 설정에서 그런 작업을 위한 스크립트 파일을 정의하고 실행 순서를 지정할 수 있다. 대략 다음과 같은 구조를 가진다.

```yaml
init: 
  enabled: false      # 설치 후 초기화를 이용하는 경우 true
  # 초기화가 실행될 컨테이너 정보
  container:
    image: [컨테이너 이미지]
    tag: [컨테이너 이미지 태그]
    pullPolicy: [컨테이너 이미지 풀 정책]
  # 초기화에 필요한 스크립트 파일 정의
  files:
    - [쉘스크립트 이름].sh |
      [쉘스크립트 내용] 
  # 초기화 명령어 리스트 (순서대로 실행)
  commands: 
    - [쉘스크립트 이름].sh
```

`files` 섹션에 초기화에 필요한 파일의 구현을 기술하고, 그 아래 `commands` 에서 지정한 순서대로 그 파일들을 실행하여 초기화를 진행하게 된다.

아래는 앞에서 사용한 툴 컨테이너 이미지를 이용해 DB 를 초기화하는 예이다. 

```yaml
init:
  enabled: true
  container:
    image: "haje01/alpaka-tool"
    tag: 0.0.5
    pullPolicy: IfNotPresent
  files:
  - init_database.sh: |
    echo "> run 'init_database.sh'"
    mysql -u myuser -e "CREATE DATABASE test"
  commands:
  - init_database.sh
```

### 설치 후 진행할 테스트 설정 

알파카는 설치 후 잘 동작하는지 확인을 위해 기본적인 테스트 코드를 제공한다. 자세한 것은 아래의 **설치 후 활용 / 테스트** 부분을 참고하고, 여기에서는 테스트 설정에 관해서만 설명하겠다. 설정은 대략 다음과 같은 구조를 가진다.

```yaml
test:
  enabled: true     # 설치 후 테스트를 진행하는 경우 true
  # 테스트용 컨테이너 정보 
  container:
    image: "haje01/alpaka-tool"
    tag: 0.0.5
    pullPolicy: IfNotPresent
  # 테스트용 카프카 커넥트별 정보
  connects:
    # 소스 커넥트 정보
    srccon:
      container:
        image: "haje01/kafka-srccon"
        tag: 0.0.5
        pullPolicy: IfNotPresent
    # 싱크 커넥트 정보 
    sinkcon:
      container:
        image: "haje01/kafka-sinkcon"
        tag: 0.0.4
        pullPolicy: IfNotPresent
  # S3 싱크 커넥터 테스트 정보 
  s3sink:
    enabled: false
    # bucket: S3 싱크 커넥터가 사용할 버킷
    # topics_dir: S3 싱크 커넥터가 사용할 버킷내 디렉토리 
    # region: S3 싱크 커넥터가 사용할 AWS 리전
  envs: []
  # - name: AWS_ACCESS_KEY_ID
  #   value: 액세스 키값
  # - name: AWS_SECRET_ACCESS_KEY 
  #   value: 시크릿 키값
  # - name: AWS_DEFAULT_REGION
  #   value: ap-northeast-2
```

테스트는 설치 후 자동으로 진행되는데, 만약 모든 테스트를 원하지 않으면 아래와 같이 설정파일에 기술한다.

```yaml
test:
  enabled: false
```

테스트는 크게 관련 툴 테스트, 카프카 브로커 및 커넥트 테스트로 나뉜다. 카프카 커넥트 테스트는 소스 커넥트 `srccon` 와 싱크 커넥트 `sinkcon` 로 구분하여 기술한다. 현재는 각각 JDBC 소스 커넥터 및 S3 싱크 커넥터 테스트를 수행한다. 

S3 싱크 커넥터 테스트를 위해서는 `s3sink` 블럭에 `enabled: true` 로 하고, AWS 환경 변수를 기입하여야 한다. 이 때 주의할 점은 `bucket`으로 지정한 S3 버킷 아래 `topics_dir` 디렉토리의 내용물은 지워지게 된다는 점이다. 만약 이 정보를 잘못 설정하면 **원치 않는 경로의 파일들이 지워질 수 있다!**

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
alpaka/alpaka   0.0.4           3.3.1           Yet another Kafka deployment chart.
```

앞서 작성해 둔 예제 설정 파일을 이용하면 다음과 같이 설치할 수 있다.

```bash
helm install -f configs/mymkb.yaml my alpaka/alpaka 
```

저장소에 등록된 패키지에서 설치하려면 다음처럼 한다 (`alpaka/alpaka` 는 `저장소/차트명` 이다). 버전을 명시하여 설치할 수도 있다.

```bash
helm install -f configs/mymkb.yaml my alpaka/alpaka --version 0.0.4
```

폐쇄망처럼 외부 접속이 곤란한 경우 `alpaka/chartrepo` 아래에 있는 특정 버전의 패키지 파일에서 직접 설치할 수도 있다.

```bash
helm install -f config/mymkb.yaml my chartrepo/alpaka-0.0.4.tgz
```

혹은 다음처럼 패키지 파일내 `charts/` 디렉토리만 로컬로 복사하여 이용할 수도 있다.

```bash
tar xzvf chartrepo/alpaka-0.0.4.tgz alpaka/charts
helm install -f config/mymkb.yaml my alpaka/
```

#### 로컬 코드에서 설치하기

Git 을 통해 내려받은 코드를 이용해 설치할 수 있다 (이후 설명은 내려받은 코드의 디렉토리 기준). YAML 파일을 수정해보면서 테스트할 때는 코드에서 설치하는 것이 편할 것이다.

먼저 의존 차트를 내려 받는 과정이 필요하다.  차트 정보 `Chart.yaml` 파일이 있는 `alpaka/alpaka/` 디렉토리로 이동 후 다음처럼 수행한다.

```bash
helm dependency update
```

차트 정보 파일을 보면 어떤 외부 차트가 설치되는지 파악할 수 있다.

> 다음 차트들은 버그가 있어 패치된 것을 이용한다.
>
> - `kminion` - `policy/v1beta` 의 호환성 문제
> - `bitnami/kube-prometheus` - Ingress 에서 `hostname` 에 `*` 를 주면 [에러 발생](https://github.com/bitnami/charts/issues/14070)
> - `provectus/kafka-ui` - 차트 저장소가 사라짐
> - `ksqldb` - `nodeSelector` 를 지원하지 않음 

외부 의존 차트를 다 받았으면, 다시 상위 디렉토리로 이동 하여 다음과 같이 로컬 코드에서 설치한다.

```bash
helm install -f configs/mymkb.yaml my alpaka/
```

> `alpaka/` 는 차트가 있는 디렉토리 명이다.

### 설치 후 활용

#### 테스트

앞서 설명했던 것처럼 `test.enabled` 가 `true` 인 경우 설치 후 자동으로 기본 테스트가 돌아가는데, 이를 위해 테스트를 위한 잡, 파드 및 MySQL DB 가 설치되게 된다.

`[배포 이름]-alpaka-test-[임의 문자열]` 형식의 파드가 테스트를 위한 것으로, 이것은 [배포 이름]-alpaka-test` 형식의 Job 을 통해 시작된 것이다. 현재 다음과 같은 테스트를 진행한다.

- 관련 패키지 (그라파나, 프로메테우스, UI for Kafka, 쿠버네티스 대쉬보드) 웹 접속 테스트
- MySQL DB 에 있는 정보를 JDBC 소스 커넥터를 통해 카프카로 가져오기 테스트
- 카프카 토픽을 S3 싱크 커넥터를 통해 AWS S3 로 올리기 테스트
- 기본적인 ksqlDB 동작 테스트 

앞으로 좀 더 다양한 테스트가 추가될 수 있을 것이다.

만약 테스트가 실패하면 다음과 같이 실패 메시지를 확인하여 문제를 파악할 수 있다.

```
kubectl logs job/[배포 이름]-alpaka-test
```

이미 설치 및 수행된 테스트 관련 리소스를 제거하려면, 설정 파일의 `test.enabled` 를 `false` 로 수정후 Helm 업그레이드를 하면 된다.

```
helm upgrade -f configs/_mkb.yaml mkb alpaka
```

테스트용 MySQL 을 비롯한 관련 리소스가 제거된 것을 확인할 수 있을 것이다.

> 업그레이드 후에도 테스트를 위해 등록된 커넥터 `jdbc_source_mysql` 가 남아 있는데, 별 문제는 없을 것이다. 찜찜하면 ui4kafka 등을 통해 지워주도록 하자.

#### 설치 노트

설치가 성공하면 노트가 출력되는데 이를 활용에 참고하도록 하자. 아래는 예제 설정 파일을 통해 설치한 경우의 노트이다.

> `helm status my` 명령으로 다시 볼 수 있다.

```markdown
NAME: my
LAST DEPLOYED: Thu Feb 23 13:45:44 2023
NAMESPACE: default
STATUS: deployed
REVISION: 1
NOTES:
# 설정 파일에 기술된 쿠버네티스 배포판

k3d

# 설치된 파드 리스트

kubectl get pods --namespace default -l app.kubernetes.io/instance=my

# 카프카 브로커 URL

my-kafka-headless:9092

# 알파카 Tool 에 접속

export TOOL_POD=$(kubectl get pods -n default -l "app.kubernetes.io/instance=my,app.kubernetes.io/component=alpaka-tool" -o jsonpath="{.items[0].metadata.name}")
kubectl exec -it $TOOL_POD -n default -- bash

# 테스트용 MySQL

root 사용자 암호

MYSQL_ROOT_PASSWORD=$(kubectl get secret --namespace default my-test-mysql -o jsonpath="{.data.mysql-root-password}" | base64 -d)

# 테스트 로그 확인

export TEST_POD=$(kubectl get pod -n default  -l "job-name=my-alpaka-test-run-1" -o jsonpath="{.items[0].metadata.name}")
kubectl logs -f $TEST_POD

# ksqlDB 접속

export KSQL_POD=$(kubectl get pods -n default -l "app.kubernetes.io/name=ksqldb,app.kubernetes.io/instance=my" -o jsonpath="{.items[0].metadata.name}")
kubectl exec -it $KSQL_POD -n default -- ksql
```

#### 웹 접속하기 

앞서 예제에서 설명한대로 인그레스가 잘 설정되었다면 외부에서 알파카를 통해 설치된 각종 서비스의 웹페이지에 접속이 가능하다.

> 윈도우 WSL (Windows Subsystem for Linux) 환경에서 minikube 를 이용하는 경우, 아래와 같이 터널링해주어야 인그레스를 외부에서 접근할 수 있다 (WSL 에서 k3s 를 사용하는 경우는 비슷한 방법을 찾기 힘들었다).
>
> `minikube tunnel`
> 
> 이후 호스트 파일 (macOS/Linux 는 `/etc/hosts`, 윈도우는 `C:\Windows\System32\drivers\etc\hosts`) 에서 아래와 같이 추가해주면 윈도우상의 웹브라우저에서 도메인 이름으로 접속이 가능하다 ([참고](https://www.liquidweb.com/kb/edit-host-file-windows-10/)
>
> `127.0.0.1  grafana.alpaka.wai`
> `127.0.0.1  k8dashboard.alpaka.wai`
> `127.0.0.1  ui4kafka.alpaka.wai`
> `127.0.0.1  prometheus.alpaka.wai`
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

EKS 의 인그레스는 결과적으로 AWS 의 ALB (Application Load Balancer) 를 이용하게 되는데, 여기서는 도메인 없이 사용하기에 위의 경우 `k8s-public-1946ec9e92-2144952281.ap-northeast-2.elb.amazonaws.com` 주소로 접속하면 되겠다. 앞서 설명한 대로 서비스 별로 접속 포트가 다른데, 아래를 참고하자. 

- Kubernetes Dashboard : `8443`
- UI for Kafka : `8080`
- Grafana : `3000`
- Prometheus : `9090`

예를 들의 위 예에서는 `k8s-public-1946ec9e92-277402474.ap-northeast-2.elb.amazonaws.com:3000` 주소로 그라파나에 접속할 수 있다.

> `Ingress` 는 원래 `80 (HTTP)` 및 `443 (HTTPS)` 포트로만 접근이 가능하다. 위 예처럼 포트를 달리하여 다양한 서비스에 접속하는 방식은 AWS ALB 에 특화된 팁으로 볼 수 있다.
> 보다 정통적인 방법은 서브 도메인을 이용하는 것이다.

### 삭제 

사용하지 않는 클러스터는 아래와 같이 삭제할 수 있다.

```bash
helm uninstal myteste
```

중요한 점은 설치시 생성된 PVC 는 삭제되지 않는 것이다. 이는 중요한 데이터 파일을 실수로 삭제하지 않기 위함으로, 필요없는 것이 확실하다면 아래처럼 삭제해 주자.

```bash
kubectl delete pvc --all
```

## 기타

### 파드를 적절한 노드에 배포하기 

하나 이상의 노드로 구성된 클러스터의 경우 어떤 노드에 어떤 파드가 위치할지가 중요한 경우가 있다. 

[이곳](https://waspro.tistory.com/582) 을 참고하면 쿠버네티스 클러스터 노드는 크게 다음과 같은 역할로 분류할 수 있다:

- 마스터 - K8S 를 관리하는 컨트롤러 배포
- 인프라 - 인프라적인 에코 시스템 (모니터링, 로깅, 트레이싱 등)
- 워커 - 실제 앱이 배포 
- 잉그레스 - Ingress 컨트롤러 배포

예를 들어 알파카의 경우 카프카 브로커는 워커 노드에, 프로메테우스 및 그라파나는 인프라 노드, 그리고 K8S 컨트롤러는 마스터 노드에 배포되는 것이 맞을 것이다. 

여기에서는 편의상 두 개 노드의 예로 설명하겠는데, 이처럼 역할별로 노드를 배정하기에 부족한 경우 다음처럼 하나의 노드가 하나 이상의 역할을 하도록 구성될 수도 있겠다.
 
- `agent-01` - 인프라 + 알파 역할
- `agent-02` - 워커 + 알파 역할

> 로컬에서 멀티 노드 배포 테스트를 하기 위해서는 k3d 를 이용하면 편리할 것이다.


이 경우 각 노드에 아래와 같이 라벨을 부여하고,

```
kubectl label nodes agent-01 alpaka/node-type=infra
kubectl label nodes agent-02 alpaka/node-type=worker
```

각 노드별로 아래와 같이 파드가 배포되기를 원한다고 하자.
- agent-01 (인프라)
  - 프로메테우스
  - 그라파나
  - UI for Kafka
  - 쿠버네티스 대쉬보드
  - KMinion
  - ksqlDB
  - 툴 컨테이너
- agent-02 (워커)
  - 주키퍼
  - 카프카 브로커
  - 카프카 커넥터
  - 초기화 및 테스트 관련

설정 파일에서 다음처럼 `nodeSelector` 를 추가 기술하면 파드가 역할에 맞는 노드에 배포될 것이다 (실제 사용하는 패키지에 대해서만 기술하면 된다).

```
kafka:
  nodeSelector:
    alpaka/node-type: worker
  zookeeper:
    nodeSelector:
      alpaka/node-type: worker
  metrics:
    kafka:
      nodeSelector:
        alpaka/node-type: worker

ui4kafka:
  nodeSelector:
    alpaka/node-type: infra

prometheus:
  prometheus:
    nodeSelector:
      alpaka/node-type: infra
  operator:
    nodeSelector:
      alpaka/node-type: infra
  alertmanager:
    nodeSelector:
      alpaka/node-type: infra
  blackboxExporter:
    nodeSelector:
      alpaka/node-type: infra

grafana:
  grafana:
    nodeSelector:
      alpaka/node-type: infra

kminion:
  nodeSelector:
    alpaka/node-type: infra

k8dashboard:
  nodeSelector:
    alpaka/node-type: infra

kafka_connect:
  connects:
  - type: srccon
    nodeSelector:
      alpaka/node-type: worker

ksqldb:
  nodeSelector:
    alpaka/node-type: infra

tool:
  nodeSelector:
    alpaka/node-type: infra

init:
  nodeSelector:
    alpaka/node-type: worker

test:
  nodeSelector:
    alpaka/node-type: worker
  connects: 
    srccon:
      nodeSelector:
        alpaka/node-type: worker
    sinkcon:
      nodeSelector:
        alpaka/node-type: worker

```

### alpaka 레포지토리 갱신

알파카의 내용 및 관련 패키지 수정이 필요한 경우 `alpaka/Chart.yaml` 파일의 `version` 또는 `appVersion` 을 필요에 따라 수정하고, 알파카 코드 디렉토리에서 아래와 같이 패키지를 생성한다. 

```bash
helm package alpaka/
```

그러면 `alpaka-0.0.4.tgz` 와 같은 패키지 파일이 생성되는데, 이것을 `chartrepo` 디렉토리로 옮긴 후, `chartrepo` 디렉토리에서 인덱스 파일을 생성한다 (하나 이상의 패키지 파일이 있어도 괜찮다).

```bash
helm repo index .
```
이제 `chartrepo/` 디렉토리에 패키지 및 인덱스 파일이 존재하는지 확인 후 커밋하면 된다.
