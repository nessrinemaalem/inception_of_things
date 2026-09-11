#!/bin/bash
# =============================================================================
# check_p3.sh — verification de la p3 pour la peer-evaluation.
#
#     ./p3/scripts/check_p3.sh
#         verifie le cluster, les 2 namespaces, Argo CD, l'Application et
#         repond a la question "quelle version est deployee ?".
#
#     ./p3/scripts/check_p3.sh --switch
#         joue la DEMONSTRATION complete : bascule la version dans le depot
#         GitHub (v1 <-> v2), pousse, force le rafraichissement d'Argo CD et
#         verifie que l'application a bien change toute seule.
# =============================================================================
set -eu

CLUSTER_NAME="iot"
APP_URL="http://localhost:8888"
# Clone local du depot surveille par Argo CD (modifiable si tu le deplaces)
APP_REPO_DIR="${APP_REPO_DIR:-$HOME/Bureau/imaalem-iot-app}"

SWITCH=0
[ "${1:-}" = "--switch" ] && SWITCH=1

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

section () {
  echo
  echo -e "${BOLD}=== $1 ===${NC}"
}

fail () {
  echo -e "${RED}${BOLD}KO : $1${NC}"
  exit 1
}

# Renvoie la version servie par l'application ("v1" ou "v2")
app_version () {
  curl -s --max-time 10 "${APP_URL}" 2>/dev/null \
    | grep -o '"v[0-9]"' | tr -d '"' | head -1
}

# -----------------------------------------------------------------------------
section "Le cluster k3d"
# -----------------------------------------------------------------------------
k3d cluster list | grep -E "^(NAME|${CLUSTER_NAME})" \
  || fail "le cluster '${CLUSTER_NAME}' n'existe pas (lance setup.sh)"

echo
# La preuve de ce qu'est k3d : un node Kubernetes EST un conteneur Docker.
echo "Vu par Kubernetes :"
kubectl get nodes
echo
echo "Les memes, vus par Docker :"
docker ps --filter "name=k3d-${CLUSTER_NAME}" --format "  {{.Names}}  ({{.Image}})"

# -----------------------------------------------------------------------------
section "Les deux namespaces exiges par le sujet"
# -----------------------------------------------------------------------------
kubectl get ns
for ns in argocd dev; do
  kubectl get ns "${ns}" >/dev/null 2>&1 || fail "le namespace '${ns}' est absent"
done
echo
echo -e "${GREEN}OK : les namespaces 'argocd' et 'dev' existent${NC}"

# -----------------------------------------------------------------------------
section "Argo CD (namespace argocd)"
# -----------------------------------------------------------------------------
kubectl get pods -n argocd

# -----------------------------------------------------------------------------
section "L'Application Argo CD (le lien avec le depot GitHub)"
# -----------------------------------------------------------------------------
kubectl -n argocd get application
echo
echo "Depot surveille :"
kubectl -n argocd get application playground \
  -o jsonpath='  {.spec.source.repoURL}{"\n  namespace cible : "}{.spec.destination.namespace}{"\n"}'

SYNC=$(kubectl -n argocd get application playground -o jsonpath='{.status.sync.status}')
HEALTH=$(kubectl -n argocd get application playground -o jsonpath='{.status.health.status}')
[ "${SYNC}" = "Synced" ]    || fail "l'Application est '${SYNC}' au lieu de 'Synced'"
[ "${HEALTH}" = "Healthy" ] || fail "l'Application est '${HEALTH}' au lieu de 'Healthy'"
echo
echo -e "${GREEN}OK : Synced / Healthy${NC}"

# -----------------------------------------------------------------------------
section "L'application deployee (namespace dev)"
# -----------------------------------------------------------------------------
kubectl get pods -n dev
echo
echo "Image reellement deployee :"
kubectl -n dev get deployment playground \
  -o jsonpath='  {.spec.template.spec.containers[0].image}{"\n"}'

# -----------------------------------------------------------------------------
section "Test de l'application"
# -----------------------------------------------------------------------------
VERSION=$(app_version)
[ -n "${VERSION}" ] || fail "aucune reponse sur ${APP_URL}"
printf '  curl %-24s -> ' "${APP_URL}"
echo -e "${GREEN}$(curl -s --max-time 10 ${APP_URL})${NC}"

# -----------------------------------------------------------------------------
# Demonstration du cycle GitOps
# -----------------------------------------------------------------------------
if [ "${SWITCH}" -eq 1 ]; then
  [ -d "${APP_REPO_DIR}/.git" ] \
    || fail "clone du depot introuvable dans ${APP_REPO_DIR} (definis APP_REPO_DIR)"

  if [ "${VERSION}" = "v1" ]; then FROM=v1; TO=v2; else FROM=v2; TO=v1; fi

  section "Demonstration GitOps : ${FROM} -> ${TO}"
  echo "1. Modification du tag dans le depot GitHub..."
  ( cd "${APP_REPO_DIR}" \
    && git pull -q --rebase \
    && sed -i "s|wil42/playground:${FROM}|wil42/playground:${TO}|" deployment.yaml \
    && git commit -aqm "Passage de l'application en ${TO}" \
    && git push -q )
  echo "   pousse."

  echo "2. Rafraichissement force d'Argo CD..."
  # Sans cela, Argo CD interroge le depot toutes les ~3 minutes (mesure : 181 s).
  # Cette annotation declenche une verification immediate (mesure : 5 s).
  kubectl -n argocd patch application playground --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null

  echo "3. Attente du redeploiement automatique..."
  for _ in $(seq 1 36); do
    [ "$(app_version)" = "${TO}" ] && break
    sleep 5
  done

  NEW=$(app_version)
  [ "${NEW}" = "${TO}" ] || fail "l'application repond encore '${NEW}' au lieu de '${TO}'"
  echo
  echo "   Image deployee :"
  kubectl -n dev get deployment playground \
    -o jsonpath='     {.spec.template.spec.containers[0].image}{"\n"}'
  printf '   curl %-22s -> ' "${APP_URL}"
  echo -e "${GREEN}$(curl -s --max-time 10 ${APP_URL})${NC}"
  echo
  echo -e "${GREEN}OK : ${FROM} -> ${TO} deploye automatiquement, sans aucun kubectl apply${NC}"
fi

echo
echo -e "${GREEN}${BOLD}Verification terminee avec succes.${NC}"
