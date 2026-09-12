#!/bin/bash
# Verification de la partie 2, a lancer depuis l'hote : ./scripts/check_apps.sh
# ("-- -T" desactive le pseudo-terminal ssh, sinon l'affichage part en escalier)

cd "$(dirname "$0")/.."

echo
echo "########## 1. ROUTAGE PAR NOM D'HOTE ##########"
echo

echo "curl -H \"Host: app1.com\" 192.168.56.110"
curl -s -H "Host: app1.com" 192.168.56.110 | grep -o "Hello from app[0-9]"
echo

echo "curl -H \"Host: app2.com\" 192.168.56.110"
curl -s -H "Host: app2.com" 192.168.56.110 | grep -o "Hello from app[0-9]"
echo

echo "curl 192.168.56.110"
curl -s 192.168.56.110 | grep -o "Hello from app[0-9]"
echo

echo "curl -H \"Host: peu.importe.com\" 192.168.56.110"
curl -s -H "Host: peu.importe.com" 192.168.56.110 | grep -o "Hello from app[0-9]"

echo
echo "########## 2. ETAT DU CLUSTER ##########"
echo
vagrant ssh imaalemS -c "kubectl get all" -- -T

echo
echo "########## 3. LES 3 REPLIQUES D'APP2 ##########"
echo
vagrant ssh imaalemS -c "kubectl get deployment app2" -- -T
echo
vagrant ssh imaalemS -c "kubectl get pods -l app=app2 -o wide" -- -T

echo
echo "########## 4. L'INGRESS ##########"
echo
vagrant ssh imaalemS -c "kubectl get ingress" -- -T
echo
vagrant ssh imaalemS -c "kubectl describe ingress apps-ingress" -- -T

# ============================================================================
# DEMO OPTIONNELLE : le Deployment recree un Pod supprime.
# A copier-coller dans le terminal si un correcteur creuse les repliques.
#
#   POD=$(vagrant ssh imaalemS -c "kubectl get pods -l app=app2 \
#     -o jsonpath='{.items[0].metadata.name}'" -- -T)
#   vagrant ssh imaalemS -c "kubectl delete pod $POD" -- -T
#   vagrant ssh imaalemS -c "kubectl get pods -l app=app2" -- -T
#
# Attention : "kubectl delete pod -l app=app2 | head -1" supprimerait les 3,
# head ne filtre que l'affichage.
# ============================================================================
