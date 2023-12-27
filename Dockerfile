# Set the base image
FROM ubuntu:latest

RUN apt-get update \
    && apt-get install -y curl jq \
    python3 \
    py-pip \
    groff \
    less \
    mailcap \
    mysql-client \
    curl \
    py-crcmod \
    bash \
    libc6-compat \
    gnupg \
    coreutils \
    gzip \
    go \
   
