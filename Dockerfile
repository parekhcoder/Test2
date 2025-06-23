# Set the base image
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Set a persistent PATH for Go binaries
# This ensures /usr/lib/go/bin is in the PATH for all subsequent RUN commands
# and for the final running container processes (CMD/ENTRYPOINT).
ENV PATH="/usr/lib/go/bin:/usr/local/bin:/root/.local/bin:${PATH}"

# Set the working directory inside the container
WORKDIR /app

# Ensure /var/log/cron.log exists and is writable (best practice for cron)
RUN touch /var/log/cron.log && chmod 644 /var/log/cron.log

# Install all packages in a single RUN command for efficiency and smaller layers
RUN apt-get update && \
    apt-get install -y \
    curl \
    jq \
    groff \
    less \
    mailcap \
    gzip \
    gnupg \
    coreutils \
    git \
    python3 \
    python3-pip \
    mysql-client \
    python3-crcmod \
    gcc \
    make \
    golang \
    cron \
    libc6 && \
   echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update && \
    apt-get install -y google-cloud-sdk && \
    # === CRUCIAL CHANGE HERE: Move gcloud config commands INTO this RUN block ===
    gcloud config set core/disable_usage_reporting true && \
    gcloud config set component_manager/disable_update_check true && \
    gcloud config set metrics/environment github_docker_image && \
    gcloud --version && \
    # Clean up apt and pip caches
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Install Python packages using pip3
    pip3 install --break-system-packages --no-cache-dir --upgrade awscli s3cmd python-magic

RUN python3 -m site --user-base

    # Set Default Environment Variables
ENV BACKUP_CREATE_DATABASE_STATEMENT=false
ENV TARGET_DATABASE_PORT=3306
ENV SLACK_ENABLED=false
ENV SLACK_USERNAME=kubernetes-s3-mysql-backup
ENV CLOUD_SDK_VERSION=367.0.0
# Release commit for https://github.com/FiloSottile/age/tree/v1.0.0
ENV AGE_VERSION=552aa0a07de0b42c16126d3107bd8895184a69e7
ENV BACKUP_PROVIDER=aws

# Install FiloSottile/age (https://github.com/FiloSottile/age)
RUN git clone https://filippo.io/age && \
    cd age && \
    git checkout $AGE_VERSION && \
    go build -o . filippo.io/age/cmd/... && cp age /usr/local/bin/

# Set Google Cloud SDK Path
#ENV PATH /google-cloud-sdk/bin:$PATH

# Install Google Cloud SDK
#RUN curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${CLOUD_SDK_VERSION}-linux-x86_64.tar.gz && \
#    tar xzf google-cloud-sdk-${CLOUD_SDK_VERSION}-linux-x86_64.tar.gz && \
#    rm google-cloud-sdk-${CLOUD_SDK_VERSION}-linux-x86_64.tar.gz && \
#    export PATH="${PWD}/google-cloud-sdk/bin:${PATH}" && \
#    gcloud config set core/disable_usage_reporting true && \
#    gcloud config set component_manager/disable_update_check true && \
#    gcloud config set metrics/environment github_docker_image && \
#    gcloud --version

#ENV PATH="/app/google-cloud-sdk/bin:${PATH}"

RUN rm -rf /var/lib/apt/lists/*
# Copy backup script and execute
COPY resources/backup.sh /app/backup.sh
# COPY resources/logging.sh /
RUN chmod +x /app/backup.sh

COPY resources/setup_cron.sh /app/setup_cron.sh
RUN chmod +x /app/setup_cron.sh

# RUN chmod +x /logging.sh
#CMD ["/app/backup.sh"]
CMD ["/app/setup_cron.sh"]
