# 알파카 에서 사용하는 도커 파일들

## Dockerfile.tool

- 알파카 클러스터 테스트 및 운영용 이미지
- 우분투 기반으로 vim, curl, nslookup, nc, python 등의 패키지가 설치되어 있음

다음과 같이 빌드

```
$ docker build -t haje01/alpaka-tool[:버전] -f Dockerfile.tool .
```

## Dockerfile.srccon

- 카프카 소스 커넥트 용 이미지
- 아래와 같은 패키지가 설치되어 있음
  - JDBC Source 커넥터 (커스텀)
  - Debezium 커넥터 (MySQL & MSSQL)
  - MySQL 커넥터

다음과 같이 빌드

```
$ docker build -t haje01/kafka-srccon[:버전] -f Dockerfile.srccon .
```

## Dockerfile.sinkcon

- 카프카 싱크 커넥트 용 이미지
- 아래와 같은 패키지가 설치되어 있음
  - Confluent S3 Sink 커넥터

다음과 같이 빌드

```
$ docker build -t haje01/kafka-sinkcon[:버전] -f Dockerfile.sinkcon .
```