FROM jenkins/jenkins:lts

USER root

RUN apt-get update && \
    apt-get install -y default-mysql-client && \
    apt-get clean

USER jenkins