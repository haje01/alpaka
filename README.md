# alpaka

Kubernetes 기반의 Kafka + 관련 패키지 배포본. 다음과 같은 패키지를 포함한다:

- Kafka
- Zookeeper
- JDBC 커넥터 + CLI
- UI for Kafka
- Prometheus (+ KMinion)
- Grafana (+ 각종 대쉬보드)
- K8S Dashboard


## 사전 준비

개발용으로는 로컬 쿠버네티스 환경을, 프로덕션 용으로는 클라우드 또는 IDC 에 배포할 수 있다.

### 로컬 쿠버네티스 환경

주의할 것:
- 메모리나 너무 작으면 파드가 죽음 
- 디스크 용량이 너무 작으면 PVC 할당이 안됨

#### Minikube 이용시

코어 4개, 메모리 8GB, 디스크 40GB 예:
`minikube start --cpus=4 --memory=8g --disk-size=40g`

#### K3D 이용시 

워커노드 4대, 노드별 메모리 2GB 예:
`k3d cluster create dev --agents=4 --agents-memory=2gb`

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

알파카에서 제공하는 다양한 패키지의 웹페이지를 접근하기 위해서 Ingress 를 사용한다. EKS 상에서 Ingress 를 사용하기 위해 아래 작업이 필요하다.

AWS 로드밸런서 컨트롤러 설치
( 참고 : [Installing the AWS Load Balancer Controller add-on](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html) )

1. IAM Policy 파일 받기
```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.4/docs/install/iam_policy.json
```

2. IAM Policy 생성 ( 정책 이름 : `AWSLoadBalancerControllerIAMPolicy` )
```bash
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

3. IAM Role 만들기( 역할 이름 : `AmazonEKSLoadBalancerControllerRole` )
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
```helm repo add eks https://aws.github.io/eks-charts```

로컬 저장소 갱신
```helm repo update```

설치
```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=prod \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller 
```

> 주의: 배포된 차트의 보안 업데이트
> kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

설치 확인
```kubectl get deployment -n kube-system aws-load-balancer-controller```

## 설치와 삭제

설치는 저장소에서 바로 설치하는 방법과 로컬에 있는 alpaka 코드에서 설치하는 두 가지 방법으로 나뉜다.

두 방법 모두 배포 환경에 맞는 설정이 필요한데, `alpaka/values.yaml` 을 참고하여 커스텀 설정을 만들 수 있다. `configs/` 디렉토리 아래 `dev.yaml` 및 `prod.yaml` 파일을 참고하자.

### 저장소에서 바로 설치하기

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
helm install -f configs/prod.yaml pro alpaka/alpaka --version 0.0.1
```

### 로컬 코드에서 설치하기

git 을 통해 내려받은 코드를 이용해 설치할 수 있다 (이후 설명은 내려받은 코드의 디렉토리 기준이다). 

먼저 의존 패키지 빌드가 필요한데, `alpaka/` 디렉토리로 이동 후 다음처럼 수행한다.

```bash
helm dependency build
```

> kminion 의 경우 `policy/v1beta` 의 호환성 문제로 패치된 버전 사용하고 있다.

다시 상위 디렉토리로 이동 후, 다음과 같이 로컬 코드에서 설치할 수 있다.

```bash
helm install -f configs/prod.yaml prod alpaka/
```

### 삭제 

아래와 같이 삭제할 수 있다.
```bash
helm uninstal prod
```

중요한 점은 설치시 생성된 PVC 는 삭제되지 않는 것이다. 이는 중요한 데이터 파일을 실수로 삭제하지 않기 위함으로, 필요없는 것이 확실하다면 아래처럼 삭제해 주자.

```bash
kubectl delete pvc --all
```

## 유지 보수

### alpaka 패키지 파일 갱신

alpaka 의 내용 및 관련 패키지 수정이 필요한 경우 `alpaka/Chart.yaml` 파일의 `version` 또는 `appVersion` 을 필요에 따라 수정하고, 아래와 같이 패키지 파일을 갱신한다.

```bash
helm repo index alpaka/
```

그러면 `alpaka-0.0.1.tgz` 와 같은 파일이 생성되는데, 이것을 `chartrepo` 디렉토리로 이동 후 커밋하면 된다.
