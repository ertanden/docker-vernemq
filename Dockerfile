# BUILD IMAGE
FROM erlang:19-slim as build
LABEL maintainer="Ertan Deniz <ertanden@gmail.com>"

WORKDIR /vernemq

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        g++ \
        make \
        git-core \
        ca-certificates \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

ENV VMQ_VERSION 1.4.2

RUN git clone -b ${VMQ_VERSION} https://github.com/erlio/vernemq.git . \
    && make rel

# RUNTIME IMAGE
FROM debian:jessie
LABEL maintainer="Ertan Deniz <ertanden@gmail.com>"

RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl1.0.0 \
        curl \
        jq \
        bash \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/opt/vernemq
WORKDIR ${HOME}

COPY --from=build /vernemq/_build/default/rel/vernemq ./

# MQTT
EXPOSE 1883

# MQTT/SSL
EXPOSE 8883

# MQTT WebSockets
EXPOSE 8080

# VerneMQ Message Distribution
EXPOSE 44053

# EPMD - Erlang Port Mapper Daemon
EXPOSE 4369

# Specific Distributed Erlang Port Range
EXPOSE 9100 9101 9102 9103 9104 9105 9106 9107 9108 9109

# Prometheus Metrics
EXPOSE 8888

# Defaults
ENV DOCKER_VERNEMQ_KUBERNETES_NAMESPACE default
ENV DOCKER_VERNEMQ_KUBERNETES_APP_LABEL vernemq
ENV DOCKER_VERNEMQ_LOG__CONSOLE console
ENV DOCKER_VERNEMQ_ALLOW_ANONYMOUS off
ENV DOCKER_VERNEMQ_LOG__CONSOLE__LEVEL debug

ADD files/vm.args ./etc/vm.args
ADD bin/rand_cluster_node.escript ./lib/rand_cluster_node.escript
ADD bin/start.sh ./bin/start.sh

RUN useradd --no-log-init -r -M -d ${HOME} -u 10001 vernemq

RUN chmod -R u+x ${HOME}/bin && \
    chgrp -R 0 ${HOME} && \
    chmod -R g=u ${HOME} /etc/passwd

USER 10001

VOLUME ["${HOME}/log", "${HOME}/data", "${HOME}/etc"]

CMD ["./bin/start.sh"]
