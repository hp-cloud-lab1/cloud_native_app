#!/bin/bash -x

alias docker="sudo docker"

export OS_USERNAME="cna-prod"
export OS_PASSWORD="$(cat $HOME/.os_prod_pwd)"
export OS_AUTH_URL="http://10.11.51.138:5000/v3"
export OS_PROJECT_NAME="CNA-PROD"
export OS_TENANT_NAME="CNA-PROD"
export OS_FLAVOR_NAME="m1.large"
export OS_IMAGE_NAME="Ubuntu 16.04"
export OS_NETWORK_NAME="swarm"
export OS_SECURITY_GROUPS="default,swarm"
export OS_SSH_USER="ubuntu"
export OS_FLOATINGIP_POOL="public"

WORKDIR="$(dirname $0)/.."

NB_AGENTS=2

cleanup() {
    HOSTS="$(docker-machine ls -f "{{.Name}}")"

    if [ -n "$HOSTS" ]; then
        docker-machine rm -y $HOSTS
    fi
}

docker-machine create --engine-storage-driver overlay2 --driver openstack manager-prod
status="$?"

tries=0
until [ "$status" -eq 0 -o "$tries" -eq 5 ]; do
    docker-machine provision manager-prod
    status="$?"
    tries="$((tries+1))"
done

unset OS_FLOATINGIP_POOL

for i in $(seq 1 "$NB_AGENTS"); do
    docker-machine create --engine-storage-driver overlay2 --driver openstack agent-prod-"$i"
    status="$?"

    tries=0
    until [ "$status" -eq 0 -o "$tries" -eq 5 ]; do
        docker-machine provision agent-prod-"$i"
        status="$?"
        tries="$((tries+1))"
    done
done

set -e
trap "cleanup" ERR

MANAGER_IP="$(docker-machine ip manager-prod)"

docker-machine scp "$HOME/proddockerCA.crt" manager-prod:/tmp

docker-machine ssh manager-prod <<'EOF'
sudo mkdir /usr/local/share/ca-certificates/docker-dev-cert
mv /tmp/proddockerCA.crt /usr/local/share/ca-certificates/docker-dev-cert
sudo update-ca-certificates
EOF

for i in $(seq 1 "$NB_AGENT"); do
    docker-machine scp "$HOME/proddockerCA.crt" agent-prod-"$i":/tmp

    docker-machine ssh agent-prod-"$i" <<'EOF'
sudo mkdir /usr/local/share/ca-certificates/docker-dev-cert
mv /tmp/proddockerCA.crt /usr/local/share/ca-certificates/docker-dev-cert
sudo update-ca-certificates
EOF
done

eval $(docker-machine env manager-prod)
docker swarm init
TOKEN="$(docker swarn join-token -q worker)"

for i in $(seq 1 "$NB_AGENT"); do
    eval $(docker-machine env agent-prod-"$i")
    docker swarm join --token "$TOKEN" manager-prod "$MANAGER_IP"
done

"$WORKDIR/docker_services.sh"
