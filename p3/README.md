# p3 — K3d et Argo CD

Un cluster **K3d** (K3s dans Docker, sans Vagrant) avec deux namespaces, et une
application déployée automatiquement depuis un dépôt GitHub public par **Argo CD**.

| Namespace | Contenu |
|---|---|
| `argocd` | Argo CD |
| `dev` | l'application `wil42/playground` (port 8888) |

Dépôt surveillé par Argo CD :
<https://github.com/nessrinemaalem/imaalem-iot-app> (public)

## Installation

```bash
# 1. L'outillage : Docker, kubectl, k3d  (une seule fois, avec sudo)
sudo bash p3/scripts/install.sh
```

⚠️ Se **déconnecter/reconnecter** ensuite, pour que le groupe `docker` prenne
effet (même contrainte que le groupe `libvirt` en p1).

```bash
# 2. Le cluster, les namespaces, Argo CD et l'Application
bash p3/scripts/setup.sh
```

Le script est idempotent : on peut le relancer sans rien casser.

## Vérification

```bash
./p3/scripts/check_p3.sh            # cluster, namespaces, Argo CD, version déployée
./p3/scripts/check_p3.sh --switch   # démonstration GitOps complète (v1 <-> v2)
```

## Tests manuels

```bash
kubectl get ns                       # argocd et dev
kubectl get pods -n dev              # le pod déployé par Argo CD
kubectl -n argocd get application    # Synced / Healthy
curl localhost:8888                  # {"status":"ok", "message": "v1"}
```

## Changer de version (le cycle GitOps)

Dans le dépôt **imaalem-iot-app**, modifier le tag dans `deployment.yaml` :

```yaml
image: wil42/playground:v1    # -> v2
```

puis `git commit && git push`. Argo CD détecte le changement et redéploie seul.

⏱️ Il interroge le dépôt toutes les **~3 minutes**. Pour ne pas attendre pendant
la correction :

```bash
kubectl -n argocd patch application playground --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## Interface web Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

<https://localhost:8080> — `admin` / mot de passe dans `p3/.argocd-password`.

## Structure

```
p3/
├── scripts/
│   ├── install.sh      Docker + kubectl + k3d
│   ├── setup.sh        cluster k3d + namespaces + Argo CD + Application
│   └── check_p3.sh     vérification (+ --switch pour la démo GitOps)
├── confs/
│   └── application.yaml   l'objet Argo CD qui relie GitHub au namespace dev
├── NOTES.md            antisèche pour la défense
└── README.md
```

## Pour la défense

Voir [NOTES.md](NOTES.md) : la différence **K3s / K3d** (explicitement demandée
par le sujet), le fonctionnement du GitOps, le piège du namespace de l'objet
`Application`, et la chaîne des ports.

## Nettoyage

```bash
k3d cluster delete iot
```
