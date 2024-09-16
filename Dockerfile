#miniconda based python 3.9 image
FROM docker.io/library/ubuntu:jammy

RUN sed -i~ -e 's,http://.*.ubuntu.com,http://linux.mirrors.es.net,' /etc/apt/sources.list

RUN \
    apt-get update        && \
    apt-get upgrade --yes && \
    apt-get install --yes    \
        wget  curl socat cron git python3 jq vim &&  \
    apt-get clean all    &&  \
    rm -rf /var/lib/apt/lists/*

ARG ACME=/opt/acme
RUN  \
    cd $ACME_HOME && \
    git clone --depth 1 https://github.com/acmesh-official/acme.sh.git $ACME

ARG KUBECTL=/opt/kubectl
RUN \
    curl -L -o ${KUBECTL} "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x ${KUBECTL}

COPY get_cert_update_ssl.sh /opt/get_cert_update_ssl.sh
RUN chmod +rx /opt/get_cert_update_ssl.sh

COPY get_cert_update_ssl_with_websrv.sh /opt/get_cert_update_ssl_with_websrv.sh
RUN chmod +rx /opt/get_cert_update_ssl_with_websrv.sh
