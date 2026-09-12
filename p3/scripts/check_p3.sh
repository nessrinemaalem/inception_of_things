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

# ============================================================================
# DEMO GITOPS : changer la version depuis GitHub et voir le cluster suivre.
# A copier-coller dans le terminal devant le correcteur.
#
#   1. Changer le tag dans le depot surveille par Argo CD :
#        cd ~/Bureau/imaalem-iot-app
#        sed -i 's|playground:v1|playground:v2|' deployment.yaml
#        git commit -am "Passage en v2" && git push
#
#   2. Forcer Argo CD a verifier tout de suite.
#      Sans cela il interroge le depot toutes les ~3 min (mesure : 181 s).
#      Avec : 5 s.
#        kubectl -n argocd patch application playground --type merge \
#          -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
#
#   3. Verifier que le redeploiement s'est fait tout seul :
#        curl localhost:8888
#        kubectl -n dev get deployment playground \
#          -o jsonpath='{.spec.template.spec.containers[0].image}'
#
#   Pour revenir en v1 : refaire les 3 etapes en inversant v2 et v1.
# ============================================================================
