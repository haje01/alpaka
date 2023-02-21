# Kafka 테스트 & 유틸리티 용 클라이언트 이미지
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
    && apt-get install -y git \
    && apt-get install -y mariadb-client \
    && apt-get install -y unzip \
    && apt-get install -y locales

RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && unzip awscliv2.zip && ./aws/install
RUN printf 'export LANGUAGE=ko_KR.UTF-8\nexport LANG=ko_KR.UTF-8\n' >> /root/.bashrc

RUN echo 'set encoding=utf-8' >> /etc/vim/vimrc.local 

# kubectl
RUN curl -sLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# for test
RUN git clone https://github.com/haje01/kfktest.git && cd kfktest && pip3 install -r requirements.txt && pip3 install -e .

RUN echo alias ll='ls -alh'
RUN echo alias kcat='kafkacat'

RUN pip install retry