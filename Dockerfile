FROM jenkins/jenkins:lts-jdk25

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    mariadb-client \
    jq \
    curl \
 && rm -rf /var/lib/apt/lists/*

USER jenkins