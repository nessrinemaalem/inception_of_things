#!/bin/bash
# Verification de la partie 3, a lancer depuis l'hote : ./scripts/check_p3.sh
# Prerequis : le cluster doit tourner (k3d cluster start iot)

echo
echo "########## 1. LE CLUSTER K3D ##########"
echo
k3d cluster list
echo
echo "Vu par Kubernetes :"
kubectl get nodes
echo
echo "Les memes, vus par Docker :"
docker ps --filter "name=k3d-iot" --format "  {{.Names}}  ({{.Image}})"

echo
echo "########## 2. LES DEUX NAMESPACES ##########"
echo
kubectl get ns

echo
echo "########## 3. ARGO CD ##########"
echo
kubectl get pods -n argocd

echo
echo "########## 4. L'APPLICATION ARGO CD ##########"
echo
kubectl -n argocd get application
echo
echo "Depot surveille :"
kubectl -n argocd get application playground -o jsonpath='{.spec.source.repoURL}{"\n"}'
echo "Namespace cible :"
kubectl -n argocd get application playground -o jsonpath='{.spec.destination.namespace}{"\n"}'

echo
echo "########## 5. L'APPLICATION DEPLOYEE (namespace dev) ##########"
echo
kubectl get pods -n dev
echo
echo "Image deployee :"
kubectl -n dev get deployment playground -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

echo
echo "########## 6. TEST DE L'APPLICATION ##########"
echo
echo "curl localhost:8888"
curl -s localhost:8888
echo
