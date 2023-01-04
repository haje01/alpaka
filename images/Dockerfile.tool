# Kafka 테스트용 클라이언트 이미지
FROM bitnami/kafka:latest

# 툴용 필요 패키지 설치
USER root
RUN apt-get update \
    && apt-get install -y curl \
    && apt-get install -y dnsutils \
    && apt-get install -y netcat \
    && apt-get install -y kafkacat \
    && apt-get install -y vim \
    && apt-get install -y iputils-ping \
    && apt-get install -y jq \
    && apt-get install -y python3 \
    && apt-get install -y python3-pip \
    && apt-get install -y git

# kubectl
RUN curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

RUN git clone https://github.com/haje01/kfktest.git && cd kfktest && pip3 install -r requirements.txt && pip3 install -e .

