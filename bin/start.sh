#!/usr/bin/env bash

IP_ADDRESS=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
VMQ_HOME=$HOME

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${VMQ_HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

# Ensure the Erlang node name is set correctly
if env | grep -q "DOCKER_VERNEMQ_NODENAME"; then
    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${DOCKER_VERNEMQ_NODENAME}/" $VMQ_HOME/etc/vm.args
else
    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${IP_ADDRESS}/" $VMQ_HOME/etc/vm.args
fi

if env | grep -q "DOCKER_VERNEMQ_DISCOVERY_NODE"; then
    echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${DOCKER_VERNEMQ_DISCOVERY_NODE}')\"" >> $VMQ_HOME/etc/vm.args
fi

# If you encounter "SSL certification error (subject name does not match the host name)", you may try to set DOCKER_VERNEMQ_KUBERNETES_INSECURE to "1".
insecure=""
if env | grep -q "DOCKER_VERNEMQ_KUBERNETES_INSECURE"; then
    insecure="--insecure"
fi

if env | grep -q "DOCKER_VERNEMQ_DISCOVERY_KUBERNETES"; then
    # Let's set our nodename correctly
    VERNEMQ_KUBERNETES_SUBDOMAIN=$(curl -X GET $insecure --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc.cluster.local/api/v1/namespaces/$DOCKER_VERNEMQ_KUBERNETES_NAMESPACE/pods?labelSelector=app=$DOCKER_VERNEMQ_KUBERNETES_APP_LABEL -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" | jq '.items[0].spec.subdomain' | sed 's/"//g' | tr '\n' '\0')
    VERNEMQ_KUBERNETES_HOSTNAME=${MY_POD_NAME}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local

    sed -i.bak -r "s/VerneMQ@.+/VerneMQ@${VERNEMQ_KUBERNETES_HOSTNAME}/" $VMQ_HOME/etc/vm.args
    # Hack into K8S DNS resolution (temporarily)
    kube_pod_names=$(curl -X GET $insecure --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt https://kubernetes.default.svc.cluster.local/api/v1/namespaces/$DOCKER_VERNEMQ_KUBERNETES_NAMESPACE/pods?labelSelector=app=$DOCKER_VERNEMQ_KUBERNETES_APP_LABEL -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" | jq '.items[].spec.hostname' | sed 's/"//g' | tr '\n' ' ')
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
                echo "Will join an existing Kubernetes cluster with discovery node at ${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local"
                echo "-eval \"vmq_server_cmd:node_join('VerneMQ@${kube_pod_name}.${VERNEMQ_KUBERNETES_SUBDOMAIN}.${DOCKER_VERNEMQ_KUBERNETES_NAMESPACE}.svc.cluster.local')\"" >> $VMQ_HOME/etc/vm.args
                break
        fi
    done
fi

if [ -f $VMQ_HOME/etc/vernemq.conf.local ]; then
    cp $VMQ_HOME/etc/vernemq.conf.local $VMQ_HOME/etc/vernemq.conf
else
    sed -i '/########## Start ##########/,/########## End ##########/d' $VMQ_HOME/etc/vernemq.conf

    echo "########## Start ##########" >> $VMQ_HOME/etc/vernemq.conf

    env | grep DOCKER_VERNEMQ | grep -v 'DISCOVERY_NODE\|KUBERNETES\|DOCKER_VERNEMQ_USER' | cut -c 16- | awk '{match($0,/^[A-Z0-9_]*/)}{print tolower(substr($0,RSTART,RLENGTH)) substr($0,RLENGTH+1)}' | sed 's/__/./g' >> $VMQ_HOME/etc/vernemq.conf

    users_are_set=$(env | grep DOCKER_VERNEMQ_USER)
    if [ ! -z "$users_are_set" ]; then
        echo "vmq_passwd.password_file = $VMQ_HOME/etc/vmq.passwd" >> $VMQ_HOME/etc/vernemq.conf
        touch $VMQ_HOME/etc/vmq.passwd
    fi

    for vernemq_user in $(env | grep DOCKER_VERNEMQ_USER); do
        username=$(echo $vernemq_user | awk -F '=' '{ print $1 }' | sed 's/DOCKER_VERNEMQ_USER_//g' | tr '[:upper:]' '[:lower:]')
        password=$(echo $vernemq_user | awk -F '=' '{ print $2 }')
        vmq-passwd $VMQ_HOME/etc/vmq.passwd $username <<EOF
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
bash -c "$VMQ_HOME/bin/vernemq config generate 2>&1 > /dev/null" | tee /tmp/config.out | grep error

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
        # this will stop the VerneMQ process
        vmq-admin cluster leave node=VerneMQ@$IP_ADDRESS -k > /dev/null
        wait "$pid"
    fi
    exit 143; # 128 + 15 -- SIGTERM
}

# Setup OS signal handlers
trap 'siguser1_handler' SIGUSR1
trap 'sigterm_handler' SIGTERM

# Start VerneMQ
$VMQ_HOME/bin/vernemq console -noshell -noinput $@
pid=$(ps aux | grep '[b]eam.smp' | awk '{print $2}')
wait $pid
