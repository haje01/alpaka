# alpaka 에서 사용하는 도커 파일들

## Dockerfile.client

- Kafka 클러스터 테스트 용 이미지
- 우분투 기반으로 vim, curl, nslookup, nc 패키지가 설치되어 있음

다음과 같이 빌드

$ docker build -t haje01/kafka-cli[:버전] -f Dockerfile.cli .

## Dockerfile.dbcon

- JDBC 소스 커넥트 용 이미지
- 아래와 같은 패키지가 설치되어 있음
  - JDBC Source 커넥터 (커스텀)
  - Debezium 커넥터 (MySQL & MSSQL)
  - MySQL 커넥터

다음과 같이 빌드

$ docker build -t haje01/kafka-dbcon[:버전] -f Dockerfile.dbcon .
