#!/bin/bash
# A lancer depuis l'hote, dans le dossier p1/ (ou n'importe ou : le script
# se replace automatiquement a la racine de p1/).
set -eu

cd "$(dirname "$0")/.."

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

section () {
  echo
  echo -e "${BOLD}=== $1 ===${NC}"
}

section "Etat des VM Vagrant"
vagrant status

section "Nodes du cluster K3s (kubectl get nodes -o wide, depuis imaalemS)"
vagrant ssh imaalemS -c "kubectl get nodes -o wide"

section "Verification : les 2 nodes doivent etre Ready"
READY_COUNT=$(vagrant ssh imaalemS -c "kubectl get nodes --no-headers" | tr -d '\r' | awk '$2 == "Ready"' | wc -l)

if [ "${READY_COUNT}" -eq 2 ]; then
  echo -e "${GREEN}OK : les 2 nodes (imaalemS + imaalemSW) sont Ready${NC}"
else
  echo -e "${RED}KO : ${READY_COUNT}/2 node(s) Ready seulement${NC}"
  exit 1
fi

section "Pods systeme (kube-system)"
vagrant ssh imaalemS -c "kubectl get pods -A"

section "Test SSH sans mot de passe sur les 2 VM"
vagrant ssh imaalemS -c "hostname" && echo -e "${GREEN}OK : SSH imaalemS${NC}"
vagrant ssh imaalemSW -c "hostname" && echo -e "${GREEN}OK : SSH imaalemSW${NC}"

echo
echo -e "${GREEN}${BOLD}Verification terminee avec succes.${NC}"
