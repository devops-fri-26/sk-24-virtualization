FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl gpg gpgv qemu-system-x86 qemu-utils && rm -rf /var/lib/apt/lists/*
COPY fetch-ubuntu.sh /usr/local/bin/fray-fetch-ubuntu
WORKDIR /vm
