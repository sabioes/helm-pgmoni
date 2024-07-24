#!/bin/bash
set -e

# set of environment variables
export NGINX_NAMESPACE=ingress-nginx-2
export CLUSTER=PROD
export HTTPPORT=8080
export GRAFANA_PASS=operator

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

echo
echo "==== install app packages"
# npm install
# export APP=`cat package.json | grep '^  \"name\":' | cut -d ' ' -f 4 | tr -d '",'`         # extract app name from package.json
# export VERSION=`cat package.json | grep '^  \"version\":' | cut -d ' ' -f 4 | tr -d '",'`  # extract version from package.json

echo "==== create new cluster ${CLUSTER}" # "for app ${APP}:${VERSION}"
cat k3d/template-k3d-config.yaml | envsubst > /tmp/k3d-config.yaml
k3d cluster create --config /tmp/k3d-config.yaml
export KUBECONFIG=$(k3d kubeconfig write ${CLUSTER})
echo "export KUBECONFIG=${KUBECONFIG}"
rm /tmp/k3d-config.yaml


echo "==== running helm for ingress-nginx"

kubectl create namespace ${NGINX_NAMESPACE}
helm install ingress-nginx ./ingress/ingress-nginx/ --set namespaceOverride="${NGINX_NAMESPACE}"

echo 
echo "---- waiting for ingress-nginx controller deployment"
kubectl rollout status deployment.apps ingress-nginx-controller -n ${NGINX_NAMESPACE} --request-timeout 5m
kubectl rollout status daemonset.apps svclb-ingress-nginx-controller -n ${NGINX_NAMESPACE} --request-timeout 5m

echo
echo "---- looking for IP of ingress-nginx controller"
i=0
while [ true ]; do
    loadbalancerip=$(kubectl get svc ingress-nginx-controller --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}" -n ${NGINX_NAMESPACE})
    [ ! -z "${loadbalancerip}" ] && break
    echo -n "."
    x=$(( ${x} + 2 ))
    [ $x -gt "100" ] && echo "ingress-nginx-controller not ready after ${x} seconds. Exit" && exit 1
    sleep 2
done
echo

echo
echo "==== show info about the cluster ${CLUSTER}"
kubectl cluster-info
echo
kubectl get all -A

# validation of the ingress installation
# kubectl get svc -A | grep traefik