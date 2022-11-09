# alpaka 에서 사용하는 도커 파일들

## Dockerfile.client

- Kafka 클러스터 테스트 용 이미지
- 우분투 기반으로 vim, curl, nslookup, nc 패키지가 설치되어 있음

다음과 같이 빌드

$ docker build -t haje01/kafka-client[:버전] -f Dockerfile.client .

## Dockerfile.dbcon

- Kafka DB 커넥트 용 이미지
- 아래와 같은 패키지가 설치되어 있음
  - JDBC Source Connector
  - MySQL


다음과 같이 빌드

$ docker build -t haje01/kafka-dbcon[:버전] -f Dockerfile.dbcon .
