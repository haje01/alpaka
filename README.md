# alpaka
Kubernetes 기반의 Kafka 배포

## 사전 준비

### 쿠버네티스 환경 (minikube, k3d 등)

주의할 것:
- 메모리나 너무 작으면 파드가 죽음 
- 디스크 용량이 너무 작으면 PVC 할당이 안됨

#### Minikube 이용시

`minikube start --cpus=4 --memory=8g --disk-size=40g`

#### K3D 이용시 

`k3d cluster create --agents=4 --agents-memory=2gb`

### 의존 패키지 설치 

`helm dependency build`
## 설치 

`helm install -f values/full.yaml full ./alpaka`
