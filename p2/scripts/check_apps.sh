#!/bin/bash
# =============================================================================
# check_apps.sh — script de verification pour la peer-evaluation (p2)
#
# A lancer depuis l'HOTE (pas dans la VM), depuis n'importe ou :
#     ./p2/scripts/check_apps.sh
#
# Option :
#     ./p2/scripts/check_apps.sh --demo
#         joue en plus la demo d'auto-reparation (supprime 1 Pod d'app2 et
#         montre que le Deployment le recree). Non joue par defaut pour ne
#         pas perturber le cluster a chaque verification.
# =============================================================================
set -eu

cd "$(dirname "$0")/.."

DEMO=0
[ "${1:-}" = "--demo" ] && DEMO=1

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

section () {
  echo
  echo -e "${BOLD}=== $1 ===${NC}"
}

# Raccourci : executer une commande kubectl dans la VM depuis l'hote.
# tr -d '\r' : vagrant ssh renvoie des fins de ligne Windows qui cassent awk.
kube () {
  vagrant ssh imaalemS -c "$*" 2>/dev/null | tr -d '\r'
}

SERVER_IP="192.168.56.110"
FAILED=0

# -----------------------------------------------------------------------------
# Test de routage : on interroge TOUJOURS la meme IP, seul l'en-tete Host change.
#   $1 = valeur de l'en-tete Host ("" = aucun en-tete, cas par defaut)
#   $2 = application attendue (app1 / app2 / app3)
# -----------------------------------------------------------------------------
check_route () {
  local host="$1" expected="$2" label body got

  if [ -z "${host}" ]; then
    label="curl ${SERVER_IP}  (aucun Host -> regle par defaut)"
    body=$(curl -s --max-time 10 "http://${SERVER_IP}" || true)
  else
    label="curl -H \"Host: ${host}\" ${SERVER_IP}"
    body=$(curl -s --max-time 10 -H "Host: ${host}" "http://${SERVER_IP}" || true)
  fi

  # Les pages renvoient "Hello from appN" : on extrait le N pour comparer.
  got=$(printf '%s' "${body}" | grep -o 'Hello from app[0-9]' | head -1)

  printf '  %-52s -> ' "${label}"
  if [ "${got}" = "Hello from ${expected}" ]; then
    echo -e "${GREEN}${got}  [OK]${NC}"
  else
    echo -e "${RED}${got:-<aucune reponse>}  [KO, attendu: Hello from ${expected}]${NC}"
    FAILED=1
  fi
}

section "Tests de routage par nom d'hote (depuis l'hote)"
check_route "app1.com" "app1"
check_route "app2.com" "app2"
check_route ""         "app3"
check_route "peu.importe.com" "app3"   # preuve que la regle par defaut attrape tout

if [ "${FAILED}" -ne 0 ]; then
  echo
  echo -e "${RED}${BOLD}KO : le routage ne correspond pas a ce qui est attendu.${NC}"
  exit 1
fi

section "Vue d'ensemble du cluster (kubectl get all)"
kube "kubectl get all"

section "L'Ingress (a montrer aux correcteurs)"
kube "kubectl get ingress"

# describe : la sortie la plus demonstrative. Elle montre d'un seul coup le
# routage par host, la regle par defaut (affichee "*", invisible dans un
# simple "get"), et les 3 IP de Pods derriere le Service app2.
section "Detail de l'Ingress : regle par defaut (*) et backends"
kube "kubectl describe ingress apps-ingress"

# -----------------------------------------------------------------------------
# Preuve des 3 repliques d'app2 (exigence du sujet)
# -----------------------------------------------------------------------------
section "Preuve 1/2 : le Deployment app2 annonce 3 repliques pretes"
kube "kubectl get deployment app2"

section "Preuve 2/2 : 3 Pods distincts portent le label app=app2"
# -l app=app2 : on execute a la main la meme requete par label que celle que
# le Service app2 pose en interne pour trouver ses Pods.
kube "kubectl get pods -l app=app2 -o wide"

# Verification automatique du 3/3
READY=$(kube "kubectl get deployment app2 --no-headers" | awk '{print $2}')
if [ "${READY}" = "3/3" ]; then
  echo
  echo -e "${GREEN}OK : app2 tourne bien en 3 repliques (${READY})${NC}"
else
  echo
  echo -e "${RED}KO : app2 est en ${READY} au lieu de 3/3${NC}"
  exit 1
fi

# -----------------------------------------------------------------------------
# Demo optionnelle : auto-reparation par le Deployment
# -----------------------------------------------------------------------------
if [ "${DEMO}" -eq 1 ]; then
  section "Demo : suppression d'UN Pod d'app2"

  # jsonpath .items[0] : on cible un seul Pod precis.
  # (Attention : "kubectl delete pod -l app=app2 | head -1" supprimerait les 3,
  #  le head ne filtre que l'affichage, pas la suppression.)
  POD=$(kube "kubectl get pods -l app=app2 -o jsonpath='{.items[0].metadata.name}'")
  echo "Pod cible : ${POD}"
  kube "kubectl delete pod ${POD}"

  section "Etat immediatement apres (un Pod est deja en cours de recreation)"
  kube "kubectl get pods -l app=app2"

  echo
  echo "Attente du retour a 3/3..."
  kube "kubectl wait --for=condition=available --timeout=60s deployment/app2"

  section "Etat final : toujours 3 Pods, le Deployment a repare tout seul"
  kube "kubectl get pods -l app=app2 -o wide"
fi

echo
echo -e "${GREEN}${BOLD}Verification terminee avec succes.${NC}"
