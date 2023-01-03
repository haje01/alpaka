# alpaka

알파카는 Kubernetes 에 Kafka + 관련 패키지를 배포하기 위한 Helm 차트이다. 다음과 같은 패키지를 포함한다:

- Kafka
- Zookeeper
- JDBC 커넥터 + CLI
- UI for Kafka
- Prometheus (+ KMinion)
- Grafana (+ 각종 대쉬보드)
- Kubernetes Dashboard


## 사전 준비

개발용으로는 로컬 쿠버네티스 환경을, 프로덕션 용도로는 클라우드 또는 IDC 에 배포할 수 있다. 알파카는 로컬 환경으로 [minikube](https://minikube.sigs.k8s.io/docs/) 와 [k3d](https://k3d.io/v5.4.6/) 를, 프로덕션 환경으로 [AWS EKS](https://aws.amazon.com/ko/eks/) 를 지원한다.

### 로컬 쿠버네티스 환경

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

### 클라우드 쿠버네티스 환경 (AWS EKS)

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

#### Ingress 준비 

알파카에서 제공하는 다양한 패키지의 웹페이지를 접근하기 위해서 Ingress 를 사용한다. EKS 상에서 Ingress 를 사용하기 위해 클러스터 생성후 아래 작업이 필요하다.

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

> 주의: 배포된 차트의 보안 업데이트
>
> ```kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"```

설치 확인

```kubectl get deployment -n kube-system aws-load-balancer-controller```

## 설치, 활용, 삭제

### 설치 

설치는 저장소에서 바로 설치하는 방법과 로컬에 있는 alpaka 코드에서 설치하는 두 가지 방법으로 나뉜다.

두 방법 모두 쿠버네티스 환경에 맞는 설정이 필요한데, `configs/` 디렉토리에 아래와 같은 기본 설정파일이 있다:
- `mkb.yaml` - minkube 용
- `k3d.yaml` - k3d 용
- `eks.yaml` - eks 용

> 위의 파일들과 `alpaka/values.yaml` 을 참고하여 커스텀 설정 파일을 만들어 이용할 수 있다.

#### 저장소에서 바로 설치하기

먼저 Helm 에 alpaka 저장소 등록이 필요하다. alpaka 는 별도 차트 저장소 없이 GitHub 저장소의 패키지 파일을 이용한다. 다음과 같이 등록하자.

```bash
helm repo add alpaka https://raw.githubusercontent.com/haje01/alpaka/master/chartrepo
```
다음과 같이 등록 결과를 확인할 수 있다.

```bash
$ helm search repo alpaka
NAME            CHART VERSION   APP VERSION     DESCRIPTION
alpaka/alpaka   0.0.1           3.3.1           Yet another Kafka deployment chart.
```

이제 다음과 같이 저장소에서 설치할 수 있다.

```bash
# minikube 의 경우 
helm install -f configs/mkb.yaml mkb alpaka/alpaka 

# k3d 의 경우 
helm install -f configs/k3d.yaml k3d alpaka/alpaka 

# eks 의 경우 
helm install -f configs/eks.yaml eks alpaka/alpaka 
```

`alpaka/alpaka` 는 `저장소/차트명` 이다. 버전을 명시하여 설치할 수도 있다.

```bash
helm install -f configs/k3d.yaml k3d alpaka/alpaka --version 0.0.1
```

#### 로컬 코드에서 설치하기

git 을 통해 내려받은 코드를 이용해 설치할 수 있다 (이후 설명은 내려받은 코드의 디렉토리 기준). 

먼저 의존 패키지 빌드가 필요한데, `alpaka/` 디렉토리로 이동 후 다음처럼 수행한다.

```bash
helm dependency build
```

> 다음 차트들은 버그가 있어 패치된 것을 이용한다.
>
> - `kminion` - `policy/v1beta` 의 호환성 문제
> - `bitnami/kube-prometheus` - Ingress 에서 `hostname` 에 `*` 를 주면 [에러](https://github.com/bitnami/charts/issues/14070)
> - `provectus/kafka-ui` - 차트 저장소가 사라짐

다시 상위 디렉토리로 이동 후, 다음과 같이 로컬 코드에서 설치할 수 있다.

```bash
# minikube 의 경우
helm install -f configs/mkb.yaml mkb alpaka/

# k3d 의 경우
helm install -f configs/k3d.yaml k3d alpaka/

# eks 의 경우
helm install -f configs/eks.yaml eks alpaka/
```

`alpaka/` 는 차트가 있는 디렉토리 명이다.

### 활용

#### 설치 노트

설치가 성공하면 노트가 출력되는데 이를 활용에 참고하도록 하자. 아래는 minikube (`mkb`) 에 설치한 경우의 설치 노트이다.

> `helm status mkb` 명령으로 다시 볼 수 있다.

```markdown
Release "mkb" has been upgraded. Happy Helming!
NAME: mkb
LAST DEPLOYED: Tue Jan  3 10:17:08 2023
NAMESPACE: default
STATUS: deployed
REVISION: 3
NOTES:
# 쿠버네티스 프로바이더 : mkb

# 설치된 파드 리스트

  kubectl get pods --namespace default -l app.kubernetes.io/instance=mkb

# 카프카 브로커 호스트명

  mkb-kafka

# kafka-cli 에 접속

  export KCLI_POD=$(kubectl get pods -n default -l "app.kubernetes.io/instance=mkb,app.kubernetes.io/component=kafka-cli" -o jsonpath="{.items[0].metadata.name}")
  kubectl exec -it $KCLI_POD -n default -- bash

# 쿠버네티스 대쉬보드

  포트포워딩:
  export K8DASH_POD=$(kubectl get pods -l "app.kubernetes.io/instance=mkb,app.kubernetes.io/component=kubernetes-dashboard" -n default -o jsonpath="{.items[0].metadata.name}")
  kubectl port-forward $K8DASH_POD -n default 8443:8443

  접속 URL: https://localhost:8443

# 카프카 UI

  포트포워딩:
  kubectl port-forward svc/mkb-kafka-ui 8989:80

# 프로메테우스

프로메테우스 접속:


얼러트매니저 접속:

    포트포워딩:
    kubectl port-forward --namespace default svc/mkb-alpaka-alertmanager 9093:9093

## 그라파나

  포트포워딩:
  kubectl port-forward svc/mkb-grafana 3000

  유저: admin
  암호: admindjemals(admin어드민)
```

#### 웹 접속하기 

로컬의 `minikube` 나 `k3d` 환경에서 설치한 경우 서비스별 웹 페이지를 접속하기 위해서는 포트 포워딩이 필요하다. 설치 노트를 참고하여 필요한 서비스를 위한 포트포워딩을 해줄 수 있다.

그렇지만 이렇게 매번 포트 포워딩을 해주기가 번거로운데, 제공되는 [tmux](https://github.com/tmux/tmux/wiki) 스크립트를 이용하면 편리하다. 
>
> `tmux-mkb-portfwd.sh`  (minikube 용)
> `tmux-k3d-portfwd.sh`  (k3d 용)

AWS EKS 에 설치한 경우는 Ingress 가 만들어져 있다. 다음처럼 확인할 수 있다.

```
$ kubectl get ingress

NAME              CLASS    HOSTS   ADDRESS                                                            PORTS   AGE
eks-grafana       <none>   *       k8s-public-1946ec9e92-126312179.ap-northeast-2.elb.amazonaws.com   80      108s
eks-k8dashboard   <none>   *       k8s-public-1946ec9e92-126312179.ap-northeast-2.elb.amazonaws.com   80      108s
eks-kafka-ui      <none>   *       k8s-public-1946ec9e92-126312179.ap-northeast-2.elb.amazonaws.com   80      108s
```

EKS 의 Ingress 는 ALB 를 이용하는데, 위의 경우 `k8s-public-1946ec9e92-126312179.ap-northeast-2.elb.amazonaws.com` 주소로 접속하면 되겠다. 다만 서비스 별로 접속 포트가 다른데, 아래를 참고하자. 

- Kubernetes Dashboard : `8443`
- UI for Kafka : `8080`
- Grafana : `3000`
- Prometheus : `9090`

예를 들의 위 예에서는 `k8s-public-1946ec9e92-126312179.ap-northeast-2.elb.amazonaws.com:3000` 주소로 그라파나에 접속할 수 있다.

> `Ingress` 는 원래 `80 (HTTP)` 및 `443 (HTTPS)` 포트로 접근이 제한된다. 위 예처럼 포트를 달리하여 다양한 서비스에 접속하는 방식은 AWS ALB 에 특화된 팁으로 볼 수 있다.
> 보다 정통적인 방법은 서브도메인을 이용하는 것이다.

### 삭제 

아래와 같이 삭제할 수 있다.
```bash
# minikube 의 경우
helm uninstal mkb

# k3d 의 경우
helm uninstal k3d

# eks 의 경우
helm uninstal eks

```

중요한 점은 설치시 생성된 PVC 는 삭제되지 않는 것이다. 이는 중요한 데이터 파일을 실수로 삭제하지 않기 위함으로, 필요없는 것이 확실하다면 아래처럼 삭제해 주자.

```bash
kubectl delete pvc --all
```

## 기타

### alpaka 패키지 파일 갱신

알파카의 내용 및 관련 패키지 수정이 필요한 경우 `alpaka/Chart.yaml` 파일의 `version` 또는 `appVersion` 을 필요에 따라 수정하고, 알파카 디렉토리에서 아래와 같이 인덱스 및 패키지 파일을 갱신한다.

```bash
helm repo index alpaka/
helm package alpaka/
```

그러면 `alpaka-0.0.1.tgz` 와 같은 파일이 생성되는데, 이것을 `chartrepo` 디렉토리로 이동 후 커밋하면 된다.
