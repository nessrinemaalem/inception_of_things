#!/bin/bash
# =============================================================================
# setup.sh — monte toute l'infrastructure de la p3 :
#   1. un cluster k3d
#   2. les namespaces "argocd" et "dev"
#
# Prerequis : bash p3/scripts/install.sh (Docker, kubectl, k3d).
#
# A lancer SANS sudo (docker doit etre utilisable par ton utilisateur) :
#     bash p3/scripts/setup.sh
# =============================================================================
set -eu

CLUSTER_NAME="iot"
APP_PORT=8888      # port sur TA machine
NODE_PORT=30080    # port du Service NodePort dans le cluster

# -----------------------------------------------------------------------------
# 1. Le cluster k3d
# -----------------------------------------------------------------------------
# Rappel : k3d ne reimplemente pas Kubernetes, il lance K3s dans des conteneurs
# Docker. Un "node" du cluster = un conteneur. D'ou la creation en ~30 s, la ou
# la p2 demandait un vagrant up de plusieurs minutes.
#
# -p "8888:30080@loadbalancer" : k3d cree un conteneur load-balancer devant le
# cluster. On lui demande de publier le port 8888 de la machine hote et de le
# transmettre au port 30080 des nodes, ou notre Service NodePort ecoutera.
# Sans ce mapping, le cluster serait isole dans Docker et injoignable.
if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}[[:space:]]"; then
  echo ">>> Le cluster '${CLUSTER_NAME}' existe deja, on le garde."
else
  echo ">>> Creation du cluster k3d '${CLUSTER_NAME}'..."
  k3d cluster create "${CLUSTER_NAME}" \
    -p "${APP_PORT}:${NODE_PORT}@loadbalancer" \
    --wait
fi

# k3d ecrit le kubeconfig et bascule le contexte courant automatiquement.
echo ">>> Contexte kubectl courant : $(kubectl config current-context)"

echo ">>> Attente que le node soit Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s

# -----------------------------------------------------------------------------
# 2. Les deux namespaces exiges par le sujet
# -----------------------------------------------------------------------------
# Un namespace est un cloisonnement logique : deux objets peuvent porter le meme
# nom dans deux namespaces differents sans se gener. Le sujet en impose deux :
# un pour Argo CD (l'outil), un pour l'application deployee (dev).
#
# "create --dry-run=client -o yaml | apply -f -" : rend la creation idempotente
# (un simple "kubectl create namespace" echouerait si le namespace existe deja).
for ns in argocd dev; do
  echo ">>> Namespace '${ns}'..."
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

# -----------------------------------------------------------------------------
# 3. Argo CD
# -----------------------------------------------------------------------------
# Argo CD est l'outil de GitOps : il surveille un depot Git et applique dans le
# cluster tout ce qui s'y trouve. On installe la version "stable" officielle.
#
# Ce manifest cree une vingtaine d'objets dans le namespace argocd, dont :
#   - argocd-repo-server        : clone le depot Git et genere les manifests
#   - argocd-application-controller : compare l'etat du cluster a celui du depot
#                                     et corrige l'ecart (la boucle GitOps)
#   - argocd-server             : l'API et l'interface web
#   - argocd-redis / dex-server : cache et authentification
# Il installe aussi les CRD, notamment le type "Application" qu'on utilisera
# a l'etape D pour declarer QUOI deployer.
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"

echo ">>> Installation d'Argo CD dans le namespace argocd..."
# --server-side est INDISPENSABLE ici. En mode client (par defaut), kubectl
# recopie le manifest entier dans une annotation "last-applied-configuration"
# pour calculer les diffs futurs ; les CRD d'Argo CD sont si volumineuses que
# cette annotation depasse la limite de 256 Ko d'etcd :
#   "The CustomResourceDefinition applicationsets.argoproj.io is invalid:
#    metadata.annotations: Too long: may not be more than 262144 bytes"
# L'apply cote serveur n'utilise pas cette annotation (il suit les champs via
# managedFields) et n'a donc pas cette limite.
# --force-conflicts : necessaire si des objets ont deja ete crees en mode
# client lors d'une tentative precedente.
kubectl apply -n argocd -f "${ARGOCD_MANIFEST}" \
  --server-side --force-conflicts

# Argo CD demarre lentement (plusieurs composants, images volumineuses).
# On attend chaque Deployment plutot qu'un "sleep" arbitraire.
echo ">>> Attente du demarrage d'Argo CD (peut prendre 2-3 minutes)..."
kubectl wait --for=condition=available --timeout=600s \
  deployment --all -n argocd

# -----------------------------------------------------------------------------
# 4. Mot de passe administrateur
# -----------------------------------------------------------------------------
# A l'installation, Argo CD genere un mot de passe aleatoire pour l'utilisateur
# "admin" et le stocke dans un Secret. Un Secret encode ses valeurs en base64
# (ce n'est PAS du chiffrement, juste un encodage), d'ou le --decode.
echo ">>> Recuperation du mot de passe admin..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode)

# On le garde sous la main pour ne pas avoir a le rechercher pendant la defense.
echo "${ARGOCD_PASSWORD}" > "$(dirname "$0")/../.argocd-password"
chmod 600 "$(dirname "$0")/../.argocd-password"

# -----------------------------------------------------------------------------
# 5. L'Application Argo CD
# -----------------------------------------------------------------------------
# Declare a Argo CD le depot a surveiller et le namespace cible. A partir de
# la, Argo CD clone le depot et deploie tout seul : aucun "kubectl apply" de
# l'application n'est fait ici.
CONFS_DIR="$(cd "$(dirname "$0")/../confs" && pwd)"

echo ">>> Declaration de l'Application Argo CD..."
kubectl apply -f "${CONFS_DIR}/application.yaml"

echo ">>> Attente du premier deploiement par Argo CD..."
# Argo CD doit cloner le depot puis appliquer les manifests : le Deployment
# n'existe pas encore dans les premieres secondes. Meme piege qu'en p2 avec
# Traefik, on attend donc son APPARITION avant d'attendre son etat.
for _ in $(seq 1 60); do
  kubectl -n dev get deployment playground >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n dev rollout status deployment/playground --timeout=180s


echo
echo "================= NAMESPACES ================="
kubectl get namespaces

echo
echo "================= ARGO CD ================="
kubectl get pods -n argocd

echo
echo "================= APPLICATION (namespace dev) ================="
kubectl -n argocd get application
kubectl -n dev get all

echo
echo "============================================================"
echo "Interface web Argo CD (optionnelle, pour la defense) :"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  puis https://localhost:8080"
echo "    identifiant : admin"
echo "    mot de passe : ${ARGOCD_PASSWORD}"
echo "  (aussi enregistre dans p3/.argocd-password)"
echo "============================================================"
