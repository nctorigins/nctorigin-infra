#!/usr/bin/env bash
# Fonctions partagées par tous les services.
#
# Les quatre services de cette machine suivent le même motif : un sous-domaine,
# un bloc nginx, un certificat certbot, une unité systemd, un venv. Ce qui les
# distingue tient en quelques lignes ; tout le reste est ici, écrit une fois.
#
# DEUX RÈGLES gouvernent ce fichier, et elles se paient si on les oublie.
#
# 1. TOUT EST IDEMPOTENT. Chaque fonction doit pouvoir être rappelée sur une
#    machine déjà installée sans rien casser ni rien dupliquer. Ce n'est pas une
#    élégance : un script d'installation qu'on ne lance qu'une fois est un
#    script qu'on n'éprouve jamais, et qui échouera donc le jour où l'on en a
#    besoin. On l'éprouve en le relançant ici.
#
# 2. CE QU'ON NE PEUT PAS FAIRE, ON LE FAIT FAIRE. Un enregistrement DNS ne se
#    crée pas depuis cette machine — mais on peut afficher exactement quoi
#    taper, puis ATTENDRE. La différence entre « prérequis non satisfait, arrêt »
#    et « je vous attends, voici la ligne » est tout ce qui sépare un script
#    utilisable d'un script qu'on relance six fois.

set -euo pipefail

# --- Dire ------------------------------------------------------------------
_c_vert=$'\033[0;32m'; _c_bleu=$'\033[0;34m'; _c_jaune=$'\033[1;33m'
_c_rouge=$'\033[0;31m'; _c_gras=$'\033[1m'; _c_fin=$'\033[0m'

titre()   { printf '\n%s▶ %s%s\n\n' "$_c_gras" "$*" "$_c_fin"; }
info()    { printf '  %s\n' "$*"; }
ok()      { printf '  %s✓%s %s\n' "$_c_vert" "$_c_fin" "$*"; }
attend()  { printf '  %s…%s %s\n' "$_c_bleu" "$_c_fin" "$*"; }
alerte()  { printf '  %s⚠%s %s\n' "$_c_jaune" "$_c_fin" "$*"; }
echec()   { printf '  %s✗%s %s\n' "$_c_rouge" "$_c_fin" "$*" >&2; }
mourir()  { echec "$*"; exit 1; }

# --- Demander --------------------------------------------------------------
# INTERACTIF=0 fait taire toutes les questions et prend le défaut. Sans ce
# mode, le script devient inutilisable le jour où on l'appelle depuis autre
# chose qu'un clavier — et ce jour arrive toujours.
INTERACTIF=${INTERACTIF:-1}

demande() {
    local question="$1" defaut="${2:-}" reponse
    if [ "$INTERACTIF" != "1" ]; then
        printf '%s' "$defaut"
        return
    fi
    if [ -n "$defaut" ]; then
        read -rp "  $question [$defaut] : " reponse </dev/tty || true
        printf '%s' "${reponse:-$defaut}"
    else
        read -rp "  $question : " reponse </dev/tty || true
        printf '%s' "$reponse"
    fi
}

demande_oui_non() {
    local question="$1" defaut="${2:-o}" reponse
    if [ "$INTERACTIF" != "1" ]; then
        [ "$defaut" = "o" ]
        return
    fi
    local invite="[O/n]"; [ "$defaut" = "n" ] && invite="[o/N]"
    read -rp "  $question $invite " reponse </dev/tty || true
    reponse=${reponse:-$defaut}
    [[ "${reponse,,}" =~ ^(o|oui|y|yes)$ ]]
}

# --- Exiger ----------------------------------------------------------------
exige_root() {
    [ "$(id -u)" -eq 0 ] || mourir "Ce script écrit dans /etc : relancez-le avec sudo."
}

paquets() {
    # `apt-get install` sur un paquet déjà présent ne fait rien et rend 0 : la
    # fonction est donc idempotente sans qu'on ait à tester quoi que ce soit.
    local manquants=()
    for p in "$@"; do
        dpkg -s "$p" >/dev/null 2>&1 || manquants+=("$p")
    done
    if [ ${#manquants[@]} -eq 0 ]; then
        ok "paquets système déjà présents"
        return
    fi
    info "installation : ${manquants[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${manquants[@]}"
    ok "paquets installés"
}

compte_service() {
    local u="$1"
    if id "$u" >/dev/null 2>&1; then
        ok "compte '$u' présent"
    else
        adduser --disabled-password --gecos "" "$u" >/dev/null
        ok "compte '$u' créé"
    fi
    # `systemd-journal` pour que le compte puisse LIRE le journal de ses propres
    # services. Sans lui, toute question « regardez vos journaux » reste sans
    # réponse — mesuré, trois fois, avant d'y penser.
    for g in sudo systemd-journal; do
        if id -nG "$u" | tr ' ' '\n' | grep -qx "$g"; then
            ok "'$u' est dans le groupe $g"
        else
            usermod -aG "$g" "$u"
            ok "'$u' ajouté au groupe $g"
        fi
    done
}

# --- Le code ---------------------------------------------------------------
depot() {
    # Clone si absent, met à jour si présent. Ne touche JAMAIS à un dépôt qui a
    # du travail en cours : écraser les modifications de quelqu'un pour
    # « installer proprement » est le genre de service qu'on ne rend qu'une fois.
    local url="$1" dir="$2" user="$3" branche="${4:-main}"
    if [ -d "$dir/.git" ]; then
        if [ -n "$(sudo -u "$user" git -C "$dir" status --porcelain --untracked-files=no)" ]; then
            alerte "$dir a des modifications non enregistrées — laissé tel quel"
            return
        fi
        sudo -u "$user" git -C "$dir" fetch --quiet origin || {
            alerte "$dir : impossible de joindre l'origine, gardé en l'état"; return; }
        sudo -u "$user" git -C "$dir" checkout --quiet "$branche"
        sudo -u "$user" git -C "$dir" merge --quiet --ff-only "origin/$branche" || {
            alerte "$dir : la branche a divergé, gardée en l'état"; return; }
        ok "$dir à jour sur $branche"
        return
    fi
    info "clone de $url"
    if ! sudo -u "$user" git clone --quiet --branch "$branche" "$url" "$dir" 2>/dev/null; then
        echec "clone impossible : $url"
        info "Ces dépôts sont PRIVÉS. Sur une machine neuve il faut de quoi"
        info "s'authentifier auprès de GitHub — une clef de déploiement, ou un"
        info "jeton dans l'URL. Posez-en une, puis relancez : le script"
        info "reprendra où il s'est arrêté."
        return 1
    fi
    ok "$dir cloné"
}

venv_python() {
    # Recrée le venv seulement s'il manque ; réinstalle toujours les
    # dépendances, car `pip install -r` est idempotent et rattrape un
    # requirements.txt qui a bougé.
    local dir="$1" user="$2"
    [ -d "$dir/venv" ] || sudo -u "$user" python3 -m venv "$dir/venv"
    sudo -u "$user" "$dir/venv/bin/pip" install --quiet --upgrade pip
    if [ -f "$dir/requirements.txt" ]; then
        sudo -u "$user" "$dir/venv/bin/pip" install --quiet -r "$dir/requirements.txt"
        ok "dépendances de $(basename "$dir") installées"
    else
        alerte "$dir n'a pas de requirements.txt"
    fi
}

# --- Le DNS, attendu plutôt que supposé ------------------------------------
ip_publique() {
    # L'adresse vue de l'extérieur, qui n'est pas forcément celle d'une
    # interface : derrière un NAT, `ip addr` ment.
    curl -s -m 10 https://api.ipify.org 2>/dev/null \
        || curl -s -m 10 https://ifconfig.me 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

attends_dns() {
    local domaine="$1" ip attendu
    ip=$(ip_publique)
    [ -n "$ip" ] || { alerte "adresse publique introuvable, DNS non vérifié"; return 0; }

    while true; do
        attendu=$(dig +short A "$domaine" @1.1.1.1 2>/dev/null | tail -1)
        if [ "$attendu" = "$ip" ]; then
            ok "$domaine pointe bien vers $ip"
            return 0
        fi
        printf '\n'
        alerte "$domaine ne pointe pas encore ici."
        info "   attendu : $ip"
        info "   observé : ${attendu:-aucun enregistrement}"
        printf '\n'
        info "Chez votre registrar, créez cet enregistrement :"
        printf '\n'
        printf '      %sType%s  A\n' "$_c_gras" "$_c_fin"
        printf '      %sNom%s   %s\n' "$_c_gras" "$_c_fin" "${domaine%%.*}"
        printf '      %sValeur%s %s\n' "$_c_gras" "$_c_fin" "$ip"
        printf '      %sTTL%s   300\n\n' "$_c_gras" "$_c_fin"
        info "Sans lui, certbot échouera d'une façon qui n'explique pas pourquoi."
        printf '\n'
        if [ "$INTERACTIF" != "1" ]; then
            echec "DNS absent et mode non interactif : arrêt."
            return 1
        fi
        if ! demande_oui_non "Attendre et revérifier dans 30 s ?" o; then
            alerte "DNS non vérifié — le certificat échouera probablement."
            return 1
        fi
        attend "nouvelle vérification dans 30 s…"
        sleep 30
    done
}

# --- nginx et TLS ----------------------------------------------------------
pose_nginx() {
    # Le gabarit porte @DOMAINE@ et @PORT@ : rien n'est codé en dur, pour qu'une
    # autre machine ou un autre domaine ne demande pas de rééditer un fichier.
    local gabarit="$1" domaine="$2" port="$3"
    local cible="/etc/nginx/sites-available/${domaine}.conf"
    sed -e "s#@DOMAINE@#${domaine}#g" -e "s#@PORT@#${port}#g" "$gabarit" > "$cible"
    ln -sf "$cible" "/etc/nginx/sites-enabled/${domaine}.conf"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        ok "nginx : $domaine servi"
    else
        echec "nginx refuse la configuration :"
        nginx -t 2>&1 | sed 's/^/      /'
        return 1
    fi
}

pose_certificat() {
    local domaine="$1" courriel="${2:-}"
    if [ -d "/etc/letsencrypt/live/$domaine" ]; then
        ok "certificat déjà en place pour $domaine"
        return
    fi
    local args=(--nginx -d "$domaine" --non-interactive --agree-tos --redirect)
    [ -n "$courriel" ] && args+=(-m "$courriel") || args+=(--register-unsafely-without-email)
    if certbot "${args[@]}" >/dev/null 2>&1; then
        ok "certificat obtenu pour $domaine"
    else
        echec "certbot a échoué pour $domaine"
        info "La cause la plus fréquente est un DNS qui ne pointe pas encore ici,"
        info "ou le port 80 fermé au niveau du pare-feu de l'hébergeur — celui"
        info "de la console Hetzner, que rien sur cette machine ne peut ouvrir."
        return 1
    fi
}

# --- systemd ---------------------------------------------------------------
# --- Rotation des journaux ---------------------------------------------------
# LA LACUNE QUE CECI COMBLE, et elle valait un incident : les trois unités
# écrivent dans /var/log/<service>.log par `StandardOutput=append:`, et ce dépôt
# ne posait AUCUNE rotation. Les trois fichiers existaient sur la machine en
# service, posés par les anciens installeurs de chaque dépôt — donc une machine
# installée par ce bootstrap-ci écrivait sans borne, et personne ne l'aurait vu
# avant que le disque soit plein.
#
# Ce n'est pas une hypothèse : le 22 septembre 2026, un disque plein a mis le jeu
# à terre pendant quatre heures, par un autre fichier. On avait alors plafonné
# CETTE source-là en oubliant celle-ci.
#
# `copytruncate` et pas la rotation ordinaire : systemd garde le fichier OUVERT
# (`append:`), donc le renommer laisserait le service écrire dans l'inode
# renommé — le nouveau fichier resterait vide et la rotation serait invisible.
pose_rotation() {
    local nom="$1" journal="$2" taille="${3:-50M}"
    local cible="/etc/logrotate.d/${nom}"

    # Le fichier est créé s'il manque : logrotate ne se plaint pas d'un journal
    # absent (`missingok`), mais le créer rend l'état lisible tout de suite.
    [ -f "$journal" ] || { touch "$journal"; chmod 644 "$journal"; }

    # Écrit À CÔTÉ, validé, puis mis en place : un fichier de rotation invalide
    # laissé dans /etc/logrotate.d fait échouer la rotation de TOUS les services
    # de la machine, une fois par jour, sans rien dire. On ne pose donc que ce
    # qui a été relu.
    cat > "${cible}.nouveau" <<EOF
# Posé par nctorigin-infra (pose_rotation). Ne pas modifier à la main : le
# prochain bootstrap réécrira ce fichier.
${journal} {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    maxsize ${taille}
}
EOF

    # VÉRIFIER plutôt qu'annoncer : `--debug` analyse et simule sans rien
    # toucher. Un fichier de rotation invalide fait échouer logrotate pour TOUS
    # les services de la machine, silencieusement, une fois par jour.
    if logrotate --debug "${cible}.nouveau" >/dev/null 2>&1; then
        mv "${cible}.nouveau" "$cible"
        ok "rotation des journaux posée : $journal (14 jours, max $taille)"
    else
        echec "fichier de rotation refusé par logrotate — RIEN n'a été posé"
        # `|| true` : ce pipeline sert à MONTRER l'erreur, donc il rend non nul
        # par construction — et `set -e` tuerait la fonction juste avant le
        # nettoyage, laissant le fichier invalide en place. C'est la troisième
        # fois que cette forme mord dans ce dépôt ; d'où le commentaire.
        logrotate --debug "${cible}.nouveau" 2>&1 \
            | grep -E "^error" | sed 's/^/      /' | head -3 || true
        rm -f "${cible}.nouveau"
        return 1
    fi
}

# --- Épreuves avant mise en service ------------------------------------------
# À lancer AVANT de toucher à systemd, et c'est tout l'intérêt : un dépôt qui ne
# passe pas ses propres épreuves ne doit pas remplacer un service qui tourne.
# L'ancien installeur du jeu faisait cela et ce dépôt l'avait perdu.
#
# Hors ligne et rapide, sinon rien : ces épreuves tournent pendant une
# installation, souvent sur une machine qu'on vient de créer. Celles qui
# demandent un serveur, un port ou un modèle n'ont pas leur place ici.
verifie_epreuves() {
    local dir="$1" user="$2"; shift 2
    [ -x "$dir/venv/bin/python" ] || { alerte "venv absent : épreuves sautées"; return 0; }
    # `mktemp` et pas un nom en $$ : un chemin prévisible dans /tmp peut être
    # devancé par un lien symbolique, et ce code tourne en root.
    local sortie; sortie="$(mktemp)"
    attend "épreuves du dépôt avant mise en service"
    if ( cd "$dir" && sudo -u "$user" timeout 300 "$@" >"$sortie" 2>&1 ); then
        ok "épreuves passées — $(tail -1 "$sortie" | tr -d '\r')"
        rm -f "$sortie"
    else
        echec "ÉPREUVES EN ÉCHEC : le service N'EST PAS remplacé."
        tail -15 "$sortie" | sed 's/^/      /'
        rm -f "$sortie"
        return 1
    fi
}

pose_unite() {
    local gabarit="$1" nom="$2" dir="$3" user="$4"
    local cible="/etc/systemd/system/${nom}.service"
    sed -e "s#@DIR@#${dir}#g" -e "s#@USER@#${user}#g" "$gabarit" > "$cible"
    systemctl daemon-reload
    systemctl enable --quiet "$nom" 2>/dev/null || true
    systemctl restart "$nom"
    sleep 1
    if systemctl is-active --quiet "$nom"; then
        ok "service $nom actif"
    else
        echec "service $nom n'a pas démarré"
        journalctl -u "$nom" -n 15 --no-pager 2>/dev/null | sed 's/^/      /'
        return 1
    fi
}

# --- Tâches périodiques ----------------------------------------------------
pose_cron() {
    # Un FICHIER dans /etc/cron.d, jamais une ligne ajoutée à un crontab :
    # ajouter est le piège classique — relancer le script quatre fois donne
    # quatre entrées, donc quatre exécutions le même matin. Un fichier qu'on
    # écrase n'a pas ce défaut.
    local nom="$1" ligne="$2"
    printf 'SHELL=/bin/bash\nPATH=/usr/local/bin:/usr/bin:/bin\n%s\n' "$ligne" \
        > "/etc/cron.d/$nom"
    chmod 644 "/etc/cron.d/$nom"
    ok "tâche périodique posée : /etc/cron.d/$nom"
}

# --- Pare-feu --------------------------------------------------------------
ouvre_ports() {
    command -v ufw >/dev/null 2>&1 || { info "ufw absent, rien à ouvrir"; return; }
    ufw status 2>/dev/null | grep -q "Status: active" || {
        info "ufw inactif, rien à ouvrir"; return; }
    for p in "$@"; do
        if ufw status | grep -q "^${p}\b"; then
            ok "port $p déjà ouvert"
        else
            ufw allow "$p" >/dev/null && ok "port $p ouvert"
        fi
    done
}
