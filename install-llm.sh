echo "
********************************************************
Etape 1 : Pré requis 
Installation Docker Engine + compose-plugin (officiel)
********************************************************"

echo ">>> Step [1] Mise à jour de la liste des paquets..."

sudo apt-get update

# Installation de 3 paquets : 
# ca-certificates - autorités de certification racines
# curl - utilitaire de téléchargement
# gnupg - cryptographie et gestion de clés GPG
echo "********************************************************"
echo ">>> Step [2] Installation ou mise à jour des paquets ca-certificates, curl, gnupg"

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

# Création du répertoire des clés GPG
# /etc/apt/keyrings : dossier standard pour stocker les clés GPG
echo "********************************************************"
echo ">>> Step [3] Création du répertoire des clés GPG"

sudo install -m 0755 -d /etc/apt/keyrings

#Téléchargement de la clé publique Docker, 
#convertion du fichier de clé GPG en format binaire (.gpg) lisible par APT 
# Positionnement de la clé est placée sous /etc/apt/keyrings/docker.gpg.
echo "********************************************************"
echo ">>> Step [4] Téléchargement et vérification de la clé publique Docker"

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | sudo gpg --dearmor | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null


# Ajout du dépôt officiel Docker
echo "********************************************************"
echo ">>> Step [5] Ajout du dépôt officiel Docker"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
 | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null



# Mise à jour avec le nouveau dépot Docker
echo "********************************************************"
echo ">>> Step [6] Mise à jour avec le nouveau dépot Docker"

sudo apt-get update

# Installation de Docker et Docker Compose
echo "********************************************************"
echo ">>> Step [7] Installation de Docker"

if ! command -v docker >/dev/null 2>&1; then
  echo ">>> Installation de Docker..."
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
                         docker-buildx-plugin docker-compose-plugin
else
  echo ">>> Docker est déjà installé."
fi

# Ajout de l'utilisateur au groupe docker
echo "********************************************************"
echo ">>> Step [8] Ajout de l'utilisateur au groupe docker"

sudo usermod -aG docker $USER
newgrp docker <<EONG
echo ">>> Groupe docker appliqué pour cette session"
EONG

echo "
********************************************************
# Etape 2 : Création d'un swapfile (8 Go)
# Permet d'éviter les erreurs OOM avec seulement 8 Go de RAM
********************************************************"

echo ">>> Step [1] Vérifie si un swapfile existe déjà"
if [ -f /swapfile ]; then
  SIZE=$(sudo du -m /swapfile | cut -f1)
  if [ "$SIZE" -lt 8192 ]; then
    echo ">>> /swapfile existe mais est trop petit, recréation..."
    sudo swapoff /swapfile
    sudo rm /swapfile
    CREATE_SWAP=1
  else
    echo ">>> /swapfile de taille correcte déjà présent."
    CREATE_SWAP=0
  fi
else
  CREATE_SWAP=1
fi

# Création du swapfile si nécessaire
if [ $CREATE_SWAP -eq 1 ]; then
  echo ">>> Création du swapfile de 8G..."

  if sudo fallocate -l 8G /swapfile 2>/dev/null; then
    echo ">>> Swapfile créé avec fallocate (rapide)."
  else
    echo ">>> fallocate non disponible, utilisation de dd (plus long)..."
    sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
  fi

  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
fi

echo "********************************************************"
echo ">>> Step [2] Active le swapfile"

if [ $CREATE_SWAP -eq 1 ]; then
    sudo swapon /swapfile
    echo ">>> Swapfile activé."
else
    echo ">>> Swapfile déjà actif ou taille correcte, pas de modification."
fi

echo "********************************************************"
echo ">>> Step [3] Vérifie si la ligne est déjà dans /etc/fstab, sinon l'ajoute"
if ! grep -q '^/swapfile' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  echo ">>> /etc/fstab mis à jour pour activer le swap au démarrage."
else
  echo ">>> Entrée déjà présente dans /etc/fstab."
fi

echo "********************************************************"
echo ">>> Step [4] Vérification finale"
echo ">>> Vérification du swap activé :"
swapon --show
free -h


echo "
********************************************************
# Etape 3 : Création du projet et git init
********************************************************"
echo ">>> Step [1] création du répertoire ~/local-llm "
mkdir -p ~/local-llm && cd ~/local-llm

if [ ! -d ".git" ]; then
  git init
fi



echo "********************************************************"
echo ">>> Step [2] Création du fichier docker-compose.yml avec image OLLAMA et OPEN-WEBUI"

echo "
********************************************************
# Création de docker-compose.yml (secure defaults)
# - Ollama: pas d'exposition publique
# - Open WebUI: seulement en local sur 127.0.0.1:3000
# ********************************************************"


cat <<'EOF' | tee docker-compose.yml > /dev/null

services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    volumes:
      - ollama:/root/.ollama
    # pas besoin d'exposer 11434 publiquement; Open WebUI y accède via le réseau docker
    # décommentez la ligne suivante si vous voulez tester l'API depuis l'hôte:
    # ports:
    #   - "127.0.0.1:11434:11434"

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    depends_on:
      - ollama
    restart: unless-stopped
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      # Active la page de connexion (compte admin créé au premier accès)
      - WEBUI_AUTH=True
    ports:
      - "127.0.0.1:3000:8080"  # IHM dispo sur http://localhost:3000
    volumes:
      - openwebui:/app/backend/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  ollama:
  openwebui:

EOF
echo ">>> docker-compose.yml généré."

echo "********************************************************"
echo ">>> Step [3] Démarrage des conteneurs Ollama et Open-WebUI"

docker compose up -d

echo "********************************************************"
echo ">>> Step [4] Pause pour laisser le temps aux services de démarrer"

sleep 10

if ! docker ps | grep -q "open-webui"; then
  echo "[ERREUR] Les conteneurs ne semblent pas avoir démarré correctement."
  docker compose logs
  exit 1
fi

echo "********************************************************"
echo ">>> Step [5] Téléchargement du modèle Mistral instruct"

# Téléchargement du modèle Mistral instruct directement dans Ollama
echo "Téléchargement du modèle mistral:instruct..."

# Tirer le modèle mistral:instruct avec 3 tentatives max
MAX_RETRIES=3
COUNT=0
SUCCESS=0

while [ $COUNT -lt $MAX_RETRIES ]; do
  echo "Tentative $((COUNT+1)) sur $MAX_RETRIES pour télécharger mistral:instruct..."
  if docker exec ollama ollama pull mistral:instruct; then
    echo "[OK] Modèle téléchargé avec succès"
    SUCCESS=1
    break
  else
    echo "[ERREUR] Échec de la tentative $((COUNT+1))"
    COUNT=$((COUNT+1))
    sleep 5  # attendre 5s avant de réessayer
  fi
done

if [ $SUCCESS -eq 0 ]; then
  echo "[ERREUR] Impossible de télécharger le modèle mistral:instruct après $MAX_RETRIES tentatives"
  exit 1
fi

