# BUILD IMAGE
FROM erlang:22.0.7-alpine as build
LABEL maintainer="Ertan Deniz <ertanden@gmail.com>"

WORKDIR /vernemq

RUN apk add --update \
        build-base \
        bsd-compat-headers \
        git \
        openssl-dev \
  && rm -rf /var/cache/apk/*

ENV VMQ_VERSION 1.9.1

RUN git clone -b ${VMQ_VERSION} --single-branch --depth 1 https://github.com/erlio/vernemq.git . \
    && make rel

# RUNTIME IMAGE
FROM alpine:3.9
LABEL maintainer="Ertan Deniz <ertanden@gmail.com>"

RUN apk add --update \
        ncurses-libs \
        libstdc++ \
        openssl \
        curl \
        jq \
        bash \
  && rm -rf /var/cache/apk/*

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

RUN adduser -H -D -h ${HOME} -u 10001 vernemq

RUN chown -R vernemq ${HOME} && \
    chmod -R u+x ${HOME}/bin && \
    chgrp -R 0 ${HOME} && \
    chmod -R g=u ${HOME} /etc/passwd

USER 10001

VOLUME ["${HOME}/log", "${HOME}/data", "${HOME}/etc"]

CMD ["./bin/start.sh"]
