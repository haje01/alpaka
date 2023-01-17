# alpaka

알파카는 Kubernetes 에 Kafka + 관련 패키지를 배포하기 위한 Helm 차트이다. 다음과 같은 패키지를 포함한다:

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

도커의 특성상 리눅스 OS 만 지원한다. 여기에 먼저 지원 툴인 [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) 과 [Helm](https://helm.sh/docs/intro/install/) 을 설치하여야 한다. 각각의 링크를 참고하여 진행하자.

다음은 사용할 쿠버네티스 배포판을 선택해야 한다. 개발용으로는 로컬용 쿠버네티스 배포판을, 프로덕션 용도로는 클라우드 또는 IDC 용 배포판을 이용할 수 있다. 알파카는 로컬 용으로 [minikube](https://minikube.sigs.k8s.io/docs/), [k3s](https://k3s.io/) 및 [k3d](https://k3d.io/v5.4.6/) 를, 프로덕션 용으로 [AWS EKS](https://aws.amazon.com/ko/eks/) 을 위한 설정 파일을 기본으로 제공한다. 

다른 환경에도 조금만 응용하면 무리없이 적용할 수 있을 것이다.

### 로컬 쿠버네티스 배포판 관련

> 주의할 것:
> - 메모리가 너무 작으면 파드가 죽음 
> - 디스크 용량이 너무 작으면 PVC 할당이 안됨

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

클러스터 이름 `prod`, EC2 `m5.xlarge` 타입 4대, 디스크 100GB 최대 4대 예:

```bash
time eksctl create cluster \
--name prod \
--nodegroup-name xlarge \
--node-type m5.xlarge \
--node-volume-size 100 \
--nodes 1 \
--nodes-min 1 \
--nodes-max 4
```

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

이제 AWS EKS 에서 인그레스를 이용할 준비가 되었다. AWS EKS 의 경우 도메인 명으로 접속하려면 퍼블릭 도메인과 ACM 인증서가 필요하기에, 여기서는 도메인 없이 포트로 서비스를 구분하여 사용하는 것으로 설명하겠다. `configs/eks.yaml` 설정 파일을 보면 이를 위해 설정 파일에서 서비스 별로 인그레스를 서로 다른 포트로 요청하는 것을 확인할 수 있다. 

> 퍼블릭 도메인을 이용하는 경우:
> AWS ACM 으로 가서 퍼블릭 도메인을 위한 인증서를 만들어 주고 그 ARN 을 아래와 같이 `annotations` 아래에 기재하여야 한다.
> ```
> alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-northeast-2:111122223333:certificate/11fceb32-9cc2-4b45-934f-c8903e4f9e12 
> alb.ingress.kubernetes.io/ssl-redirect: '443'
> ```


## 설치, 활용, 삭제

### 설치 

설치는 저장소에서 바로 설치하는 방법과 로컬에 있는 alpaka 코드에서 설치하는 두 가지 방법으로 나뉜다.

두 방법 모두 이용하는 쿠버네티스 배포판에 맞는 설정이 필요한데, `configs/` 디렉토리에 아래와 같은 기본 설정 파일이 있으니 참고하도록 하자:
- `mkb.yaml` - minikube 용
- `k3s.yaml` - k3s 용
- `k3d.yaml` - k3d 용
- `eks.yaml` - eks 용

여기서는 참고용으로 쿠버네티스 배포판별로 구분하여 설정 파일을 만들었지만, 꼭 이렇게 할 필요는 없다. 실제로는 한 번 선택한 쿠버네티스 배포판 자주 바뀌지 않기에 개발/테스트/라이브 등의 용도별로 설정 파일을 만드는 것이 더 적합할 것이다.

> `alpaka/values.yaml` 는 차트에서 사용하는 기본 변수값을 담고 있다. 위의 파일들과 함께 참고하여 커스텀 설정 파일을 만들 수 있다.

#### 저장소에서 바로 설치하기

먼저 Helm 에 alpaka 저장소 등록이 필요하다. 알파카는 별도 차트 저장소 없이 GitHub 저장소의 패키지 파일을 이용한다. 다음과 같이 등록하자.

```bash
helm repo add alpaka https://raw.githubusercontent.com/haje01/alpaka/master/chartrepo
```
다음과 같이 등록 결과를 확인할 수 있다.

```bash
$ helm search repo alpaka
NAME            CHART VERSION   APP VERSION     DESCRIPTION
alpaka/alpaka   0.0.1           3.3.1           Yet another Kafka deployment chart.
```

이제 다음과 같이 저장소에서 설치할 수 있다 (설정 파일은 미리 준비되어야 한다).

```bash
# minikube 의 경우 
helm install -f configs/mkb.yaml mkb alpaka/alpaka 

# k3s 의 경우 
helm install -f configs/k3s.yaml k3s alpaka/alpaka 

# eks 의 경우 
helm install -f configs/eks.yaml eks alpaka/alpaka 
```

> 여기서는 편의상 설정 파일명과 배포 이름을 같게 하였다. 실제로는 필요에 따라 배포 이름을 다르게 줄수 있겠다.

`alpaka/alpaka` 는 `저장소/차트명` 이다. 버전을 명시하여 설치할 수도 있다.

```bash
helm install -f configs/k3s.yaml k3s alpaka/alpaka --version 0.0.1
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
helm install -f configs/mkb.yaml mkb alpaka/

# k3s 의 경우
helm install -f configs/k3s.yaml k3s alpaka/

# eks 의 경우
helm install -f configs/eks.yaml eks alpaka/
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
helm upgrade -f configs/mkb.yaml mkb alpaka
```

테스트 관련 리소스가 제거된 것을 확인할 수 있을 것이다.

#### 설치 노트

설치가 성공하면 노트가 출력되는데 이를 활용에 참고하도록 하자. 아래는 `wslmkb.yaml` 설정 파일을 이용해 단일 노드에 설치한 경우의 노트이다.

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

카프카 클러스터 생성이 완료된 후 추가적으로 초기화에 필요한 명령이 있을 수 있다. 이를 위해 설정 파일의 `init` 섹션에서 초기화 명령을 등록할 수 있다. 아래는 JDBC 소스 커넥터 등록의 예이다.

```yaml
init:
  enabled: true
  files:
    dbcon_reg_mysql.sh: |
      echo "> dbcon_reg_mysql.sh"
      # 커넥트 준비될 때까지 대기 
      until $(curl --output /dev/null --silent --head --fail http://[배포 이름]-alpaka-dbcon:8083); do
          echo "waiting for connect."
          sleep 5
      done    
      # 커넥터 등록
      curl -s -X POST http://[배포 이름]-alpaka-dbcon:8083/connectors -H "Content-Type: application/json" -d '{
        "name": "jdbc_source_mysql",
        "config": {
            "mode": "bulk",
            "connection.url": "jdbc:mysql://[배포 이름]-mysql-headless:3306/test?serverTimezone=Asia/Seoul",
            "connection.user": "root",
            "connection.password": "[DB 암호]",
            "poll.interval.ms": 3600000,
            "topic.prefix": "mysql-",
            "tasks.max": 1,
            "connector.class" : "io.confluent.connect.jdbc.JdbcSourceConnector",
            "tables.whitelist": "person"
          }
        }' | jq
  commands:
    - dbcon_reg_mysql.sh  
```

`files` 섹션에 초기화에 필요한 파일의 구현을 기술하고, 그 아래 `commands` 에서 지정한 순서대로 그 파일들을 실행하여 초기화를 진행하게 된다.

### alpaka 레포지토리 갱신

알파카의 내용 및 관련 패키지 수정이 필요한 경우 `alpaka/Chart.yaml` 파일의 `version` 또는 `appVersion` 을 필요에 따라 수정하고, 알파카 코드 디렉토리에서 아래와 같이 패키지를 생성한다. 

```bash
helm package alpaka/
```

그러면 `alpaka-0.0.1.tgz` 와 같은 패키지 파일이 생성되는데, 이것을 `chartrepo` 디렉토리로 옮긴 후, `chartrepo` 디렉토리에서 인덱스 파일을 생성한다.

```bash
helm repo index .
```
이제 `chartrepo/` 디렉토리에 패키지 및 인덱스 파일이 존재하는지 확인 후 커밋하면 된다.
