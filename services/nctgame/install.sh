#!/usr/bin/env bash
# nctgame — serveur de jeu Ludo temps réel.
#
# Sourcé par bootstrap.sh, qui a déjà posé le socle : paquets, compte de
# service, ports. Toutes les fonctions viennent de lib/common.sh.

S=nctgame
DIR="/home/$APP_USER/nctgame_server"
DOM="${DOMAINE[$S]}"
PRT="${PORT[$S]}"

depot "https://github.com/nctorigins/nctgame_server.git" "$DIR" "$APP_USER"
venv_python "$DIR" "$APP_USER"

# --- La base d'adresses IP → pays ------------------------------------------
# Elle ne se sauvegarde pas, elle se retélécharge : c'est un artefact
# reproductible, pas une donnée. La recette vit dans le dépôt du jeu, et le
# script d'installation ne fait que l'appeler — deux copies de la même logique
# finiraient par diverger, et c'est celle du dépôt qui serait juste.
#
# Son absence n'est PAS une panne : sans base, tous les joueurs tombent dans le
# réglage par défaut, ce qui est l'état prévu pour les pays qu'on ne sait pas
# identifier. On le dit plutôt que de faire échouer l'installation.
titre_geoip() { info "base d'adresses IP → pays"; }
titre_geoip
if sudo -u "$APP_USER" "$DIR/venv/bin/python" "$DIR/tools/refresh_geoip.py" \
        2>&1 | sed 's/^/    /'; then
    ok "base d'adresses en place"
else
    alerte "base d'adresses non installée — les réglages par pays ne joindront"
    alerte "personne, et tout le monde recevra le défaut. Relancez plus tard :"
    info  "  sudo -u $APP_USER $DIR/venv/bin/python $DIR/tools/refresh_geoip.py"
fi

# Le rafraîchissement mensuel. Le 3 du mois : db-ip publie le 1er, et deux
# jours de marge évitent de courir après un fichier qui n'est pas encore là.
pose_cron "nctgame-geoip" \
  "17 4 3 * * $APP_USER cd $DIR && venv/bin/python tools/refresh_geoip.py >> $DIR/data/geoip.log 2>&1"

# --- La configuration publicitaire -----------------------------------------
# ABSENTE PAR DÉFAUT, et c'est une décision, pas un oubli : sans ce fichier le
# serveur répond {"enabled": false} à tout le monde. On ne l'installe donc
# jamais d'office — allumer la publicité se demande.
if [ -f "$DIR/data/ads.json" ]; then
    ok "configuration publicitaire présente (laissée telle quelle)"
else
    info "aucune configuration publicitaire : le serveur répondra"
    info "{\"enabled\": false} à tout le monde, ce qui est l'état voulu."
    if demande_oui_non "Allumer la publicité maintenant ?" n; then
        sudo -u "$APP_USER" cp "$DIR/deploy/ads.example.json" "$DIR/data/ads.json"
        alerte "publicité ALLUMÉE. Sans compte AdMob, l'application n'affichera"
        alerte "que les blocs d'essai de Google, barrés et sans revenu."
    fi
fi

# --- Les données -----------------------------------------------------------
# Proposer plutôt que supposer : une base existante ne se remplace jamais sans
# qu'on le demande, et c'est ce qui rend le script relançable.
if [ -f "$DIR/data/nctgame.db" ]; then
    ok "base de données présente (laissée telle quelle)"
else
    copies=$(ls -1t "$DIR"/data/*.db 2>/dev/null | head -5 || true)
    if [ -n "$copies" ] && demande_oui_non "Restaurer une sauvegarde ?" n; then
        info "copies disponibles :"
        printf '%s\n' "$copies" | nl -w4 -s'. ' | sed 's/^/    /'
        n=$(demande "Laquelle (numéro), ou vide pour repartir de zéro" "")
        if [ -n "$n" ]; then
            src=$(printf '%s\n' "$copies" | sed -n "${n}p")
            [ -n "$src" ] && sudo -u "$APP_USER" cp "$src" "$DIR/data/nctgame.db" \
                && ok "restaurée depuis $(basename "$src")"
        fi
    else
        info "base vide : elle se créera au premier lancement"
    fi
fi

# --- Service, nginx, certificat --------------------------------------------
pose_unite "$ICI/services/$S/nctgame.service" "$S" "$DIR" "$APP_USER"
attends_dns "$DOM" || alerte "on continue, mais le certificat va probablement échouer"
pose_nginx "$ICI/services/$S/nginx.conf" "$DOM" "$PRT"
pose_certificat "$DOM" "$COURRIEL"

# --- L'identité des joueurs ------------------------------------------------
# Sur une machine NEUVE il n'y a aucun appareil ancien à ménager : exiger la
# preuve dès le départ est le bon réglage, et c'est le seul moment où il ne
# coûte rien. Sur une machine déjà en service, on ne touche à rien — le drapeau
# a été posé en connaissance de cause.
if [ -f /etc/systemd/system/nctgame.service.d/auth-required.conf ]; then
    ok "preuve d'identité déjà exigée"
elif demande_oui_non "Exiger la preuve d'identité des joueurs ?" o; then
    mkdir -p /etc/systemd/system/nctgame.service.d
    printf '[Service]\nEnvironment="NCTGAME_AUTH_REQUIRED=1"\n' \
        > /etc/systemd/system/nctgame.service.d/auth-required.conf
    systemctl daemon-reload && systemctl restart "$S"
    ok "preuve exigée : un join sans jeton reçoit token_required"
fi

# --- La clef d'administration ----------------------------------------------
# Fabriquée, jamais restaurée : un secret qui voyage d'une machine à l'autre
# cesse d'en être un. Elle n'est pas affichée ici — le script dit où la lire,
# au moment où il faudra la transmettre.
if [ -f /etc/systemd/system/nctgame.service.d/admin-key.conf ]; then
    ok "clef d'administration déjà posée"
elif demande_oui_non "Ouvrir l'API d'administration (fabrique une clef) ?" n; then
    mkdir -p /etc/systemd/system/nctgame.service.d
    ( umask 077
      printf '[Service]\nEnvironment="NCTGAME_ADMIN_KEY=%s"\n' "$(openssl rand -hex 32)" \
        > /etc/systemd/system/nctgame.service.d/admin-key.conf )
    chmod 600 /etc/systemd/system/nctgame.service.d/admin-key.conf
    systemctl daemon-reload && systemctl restart "$S"
    ok "administration ouverte — elle répond 401 en attendant la clef"
    info "Pour la lire, au moment de la transmettre :"
    info "  sudo sed -n 's/.*NCTGAME_ADMIN_KEY=\\(.*\\)\"/\\1/p' \\"
    info "    /etc/systemd/system/nctgame.service.d/admin-key.conf"
fi

# --- Vérification ----------------------------------------------------------
sleep 1
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$DOM/health" 2>/dev/null || echo 000)
[ "$code" = "200" ] && ok "https://$DOM/health répond 200" \
                    || alerte "https://$DOM/health répond $code"
