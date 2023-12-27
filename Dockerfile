# Set the base image
FROM ubuntu:latest

RUN apt-get update \
    && apt-get install -y curl jq \
    python3 \
   
