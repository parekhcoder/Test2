# Set the base image
FROM ubuntu:latest

RUN apt-get update \
    && apt-get install -y curl jq \
    python3 \
    python3-pip \
    groff \
    less \
    mailcap \
    mysql-client \
    curl \    
    python3-crcmod \    
    libc6 \
    gnupg \
    coreutils \
    gzip \   
    gccgo-go \
    golang-go \
    git && \
    pip3 install --upgrade awscli s3cmd python-magic && \
    export PATH=$PATH:/usr/lib/go/bin
    


    
