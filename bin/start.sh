#!/usr/bin/env bash

IP_ADDRESS=$(ip -4 addr show ${DOCKER_NET_INTERFACE:-eth0} | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sed -e "s/^[[:space:]]*//" | head -n 1)
IP_ADDRESS=${DOCKER_IP_ADDRESS:-${IP_ADDRESS}}
VMQ_HOME=$HOME

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${VMQ_HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

# Ensure the Erlang node name is set correctly
if env | grep "DOCKER_VERNEMQ_NODENAME" -q; then
    sed -i.bak -r "s/-name VerneMQ@.+/-name VerneMQ@${DOCKER_VERNEMQ_NODENAME}/" $VMQ_HOME/etc/vm.args
else
    if [ -n "$DOCKER_VERNEMQ_SWARM" ]; then
        NODENAME=$(hostname -i)
        sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${NODENAME}/" /etc/vernemq/vm.args
    else
        sed -i.bak -r "s/-name VerneMQ@.+/-name VerneMQ@${IP_ADDRESS}/" $VMQ_HOME/etc/vm.args
    fi
fi

if env | grep "DOCKER_VERNEMQ_DISCOVERY_NODE" -q; then
    discovery_node=$DOCKER_VERNEMQ_DISCOVERY_NODE
    if [ -n "$DOCKER_VERNEMQ_SWARM" ]; then
        tmp=''
        while [[ -z "$tmp" ]]; do
            tmp=$(getent hosts tasks.$discovery_node | awk '{print $1}' | head -n 1)
            sleep 1
        done
        discovery_node=$tmp
    fi
    if [ -n "$DOCKER_VERNEMQ_COMPOSE" ]; then
        tmp=''
        while [[ -z "$tmp" ]]; do
            tmp=$(getent hosts $discovery_node | awk '{print $1}' | head -n 1)
            sleep 1
        done
        discovery_node=$tmp
    fi

    sed -i.bak -r "/-eval.+/d" $VMQ_HOME/etc/vm.args 
    echo "-eval \"vmq_server_cmd:node_join('VerneMQ@$discovery_node')\"" >> $VMQ_HOME/etc/vm.args
fi

# If you encounter "SSL certification error (subject name does not match the host name)", you may try to set DOCKER_VERNEMQ_KUBERNETES_INSECURE to "1".
insecure=""
if env | grep "DOCKER_VERNEMQ_KUBERNETES_INSECURE" -q; then
    insecure="--insecure"
fi

if env | grep "DOCKER_VERNEMQ_DISCOVERY_KUBERNETES" -q; then
    DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME=${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME:-cluster.local}
    # Let's get the namespace if it isn't set
    DOCKER_VERNEMQ_KUBERNETES_NAMESPACE=${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE:-`cat /var/run/secrets/kubernetes.io/serviceaccount/namespace`}
    # Let's set our nodename correctly
    VERNEMQ_KUBERNETES_SUBDOMAIN=${DOCKER_VERNEMQ_KUBERNETES_SUBDOMAIN:-$(curl -X GET $insecure --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc.$DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME/api/v1/namespaces/$DOCKER_VERNEMQ_KUBERNETES_NAMESPACE/pods?labelSelector=$DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" | jq '.items[0].spec.subdomain' | sed 's/"//g' | tr '\n' '\0')}
    if [ $VERNEMQ_KUBERNETES_SUBDOMAIN == "null" ]; then
        VERNEMQ_KUBERNETES_HOSTNAME=${MY_POD_NAME}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}
    else
        VERNEMQ_KUBERNETES_HOSTNAME=${MY_POD_NAME}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}
    fi

    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${VERNEMQ_KUBERNETES_HOSTNAME}/" $VMQ_HOME/etc/vm.args
    # Hack into K8S DNS resolution (temporarily)
    kube_pod_names=$(curl -X GET $insecure --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc.$DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME/api/v1/namespaces/$DOCKER_VERNEMQ_KUBERNETES_NAMESPACE/pods?labelSelector=$DOCKER_VERNEMQ_KUBERNETES_LABEL_SELECTOR -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" | jq '.items[].spec.hostname' | sed 's/"//g' | tr '\n' ' ')
    for kube_pod_name in $kube_pod_names;
    do
        if [ $kube_pod_name == "null" ]
            then
                echo "Kubernetes discovery selected, but no pods found. Maybe we're the first?"
                echo "Anyway, we won't attempt to join any cluster."
                break
        fi
        if [ $kube_pod_name != $MY_POD_NAME ]
            then
                echo "Will join an existing Kubernetes cluster with discovery node at ${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}"
                echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.${DOCKER_VERNEMQ_KUBERNETES_CLUSTER_NAME}')\"" >> $VMQ_HOME/etc/vm.args
                break
        fi
    done
fi

if [ -f $VMQ_HOME/etc/vernemq.conf.local ]; then
    cp $VMQ_HOME/etc/vernemq.conf.local $VMQ_HOME/etc/vernemq.conf
    sed -i -r "s/###IPADDRESS###/${IP_ADDRESS}/" $VMQ_HOME/etc/vernemq.conf
else
    sed -i '/########## Start ##########/,/########## End ##########/d' $VMQ_HOME/etc/vernemq.conf

    echo "########## Start ##########" >> $VMQ_HOME/etc/vernemq.conf

    env | grep DOCKER_VERNEMQ | grep -v 'DISCOVERY_NODE\|KUBERNETES\|SWARM\|COMPOSE\|DOCKER_VERNEMQ_USER' | cut -c 16- | awk '{match($0,/^[A-Z0-9_]*/)}{print tolower(substr($0,RSTART,RLENGTH)) substr($0,RLENGTH+1)}' | sed 's/__/./g' >> $VMQ_HOME/etc/vernemq.conf

    users_are_set=$(env | grep DOCKER_VERNEMQ_USER)
    if [ ! -z "$users_are_set" ]; then
        echo "vmq_passwd.password_file = $VMQ_HOME/etc/vmq.passwd" >> $VMQ_HOME/etc/vernemq.conf
        touch $VMQ_HOME/etc/vmq.passwd
    fi

    for vernemq_user in $(env | grep DOCKER_VERNEMQ_USER); do
        username=$(echo $vernemq_user | awk -F '=' '{ print $1 }' | sed 's/DOCKER_VERNEMQ_USER_//g' | tr '[:upper:]' '[:lower:]')
        password=$(echo $vernemq_user | awk -F '=' '{ print $2 }')
        $VMQ_HOME/bin/vmq-passwd $VMQ_HOME/etc/vmq.passwd $username <<EOF
$password
$password
EOF
    done

    echo "erlang.distribution.port_range.minimum = 9100" >> $VMQ_HOME/etc/vernemq.conf
    echo "erlang.distribution.port_range.maximum = 9109" >> $VMQ_HOME/etc/vernemq.conf
    echo "listener.tcp.default = ${IP_ADDRESS}:1883" >> $VMQ_HOME/etc/vernemq.conf
    echo "listener.ws.default = ${IP_ADDRESS}:8080" >> $VMQ_HOME/etc/vernemq.conf
    echo "listener.vmq.clustering = ${IP_ADDRESS}:44053" >> $VMQ_HOME/etc/vernemq.conf
    echo "listener.http.metrics = ${IP_ADDRESS}:8888" >> $VMQ_HOME/etc/vernemq.conf

    echo "########## End ##########" >> $VMQ_HOME/etc/vernemq.conf
fi

# Check configuration file
$VMQ_HOME/bin/vernemq config generate 2>&1 > /dev/null | tee /tmp/config.out | grep error

if [ $? -ne 1 ]; then
    echo "configuration error, exit"
    echo "$(cat /tmp/config.out)"
    exit $?
fi

pid=0

# SIGUSR1-handler
siguser1_handler() {
    echo "stopped"
}

# SIGTERM-handler
sigterm_handler() {
    if [ $pid -ne 0 ]; then
        # this will stop the VerneMQ process, but first drain the node from all existing client sessions (-k)
        if [ -n "$VERNEMQ_KUBERNETES_HOSTNAME" ]; then
            terminating_node_name=VerneMQ@$VERNEMQ_KUBERNETES_HOSTNAME
        elif [ -n "$DOCKER_VERNEMQ_SWARM" ]; then
            terminating_node_name=VerneMQ@$(hostname -i)
        else
            terminating_node_name=VerneMQ@$IP_ADDRESS
        fi
        $VMQ_HOME/bin/vmq-admin cluster leave node=$terminating_node_name -k > /dev/null
        $VMQ_HOME/bin/vmq-admin node stop > /dev/null
        kill -s TERM ${pid}
        exit 0
    fi
}

# Setup OS signal handlers
trap 'siguser1_handler' SIGUSR1
trap 'sigterm_handler' SIGTERM

# Start VerneMQ
$VMQ_HOME/bin/vernemq console -noshell -noinput $@ &
pid=$!
wait $pid
