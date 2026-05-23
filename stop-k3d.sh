#!/bin/bash
set -e

# set of environment variables
# NGINX variable set
export NGINXNAMESPACE=ingress-nginx
export CLUSTER=local-lab
export HTTPPORT=8889
# PROMETHEUS variable set
export PROMETHEUSNAMESPACE=monitoring
export GRAFANAPASS=operator123
# POSTGRESQL variable set
export POSTGRESQLNAMESPACE=postgres
export POSTGRESPASSWORD=""
# KAFKA variable st
export KAFKANAMESPACE=kafka
# DOCKER HUB variable set
export REPOHOSTNAME="https://index.docker.io/v1/"
export REPOUSERNAME="pcarlos"
export DOCKERCONFIGJSON=""

# remove existing cluster
if [[ ! -z $(k3d cluster list | grep "^${CLUSTER}") ]]; then
  echo
  echo "==== remove existing cluster"
  read -p "K3D cluster \"${CLUSTER}\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "bailing out..."
    exit 1
  fi
  k3d cluster delete ${CLUSTER}
fi  
