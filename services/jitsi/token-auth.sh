#!/usr/bin/env bash
# token-auth.sh — ferme les salles Jitsi de ce domaine derrière un jeton signé.
#
# ⚠️ LE JEU N'EN A PLUS BESOIN. Ce script a été écrit pour la parole en direct de
# NCTGame, à l'époque où elle passait par le SDK Jitsi. Le client a abandonné
# Jitsi — son SDK prend tout l'écran, et son écran est un plateau de Ludo — et la
# parole en direct se fait maintenant de pair à pair, sans salle Jitsi, sans JWT.
# Le jeu ne délivre plus aucun jeton Jitsi : **ne lancez pas ce script pour lui.**
#
# Il reste ici parce qu'il fait correctement une chose qui peut servir un jour :
# une installation Jitsi neuve est en `anonymous`, donc qui connaît le nom d'une
# salle y entre. Si vous voulez fermer ce domaine aux inconnus, c'est par ici.
#
# CE QU'IL CHANGE, ET QUI EST DIFFICILE À DÉFAIRE : après lui, plus AUCUNE salle
# de ce domaine ne s'ouvre sans jeton. Toute application, tout usage humain, toute
# réunion qui ne présente pas de JWT se retrouve dehors du jour au lendemain. La
# commande pour s'en fabriquer un est rappelée à la fin.
#
# À LANCER AVEC sudo, UNE FOIS, SUR LA MACHINE :
#     sudo bash services/jitsi/token-auth.sh meet.nctorigin.com
#
# Il est idempotent : relancé, il constate et ne touche à rien.
set -euo pipefail

DOM="${1:-meet.nctorigin.com}"
VHOST="/etc/prosody/conf.avail/$DOM.cfg.lua"
SECRET_FILE="/etc/nctgame/jitsi.env"
APP_ID="nctgame"

rouge() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; }
vert()  { printf '\033[32m✓ %s\033[0m\n' "$*"; }
jaune() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
dit()   { printf '  %s\n' "$*"; }

# --- Redémarrer : jamais sans le demander ------------------------------------
# UN REDÉMARRAGE N'EST PAS ANODIN SUR CETTE MACHINE, qui porte quatre services :
#
#   * `nctgame` garde les parties EN MÉMOIRE. Le redémarrer ne coupe pas des
#     sockets, il DÉTRUIT toutes les parties en cours — chaque table perd la
#     sienne, au milieu d'un coup. C'est la coupure la plus coûteuse d'ici, et
#     elle est invisible pour qui ne le sait pas.
#   * `coturn` est partagé avec Jitsi : le redémarrer coupe les appels en cours
#     qui passent par le relais.
#   * `prosody` et `jicofo` coupent toutes les conférences en cours.
#
# On demande donc, avec NON par défaut, et on imprime la commande pour plus tard.
# `INTERACTIF=0` (la convention de ce dépôt) ne redémarre rien : un automate ne
# décide pas d'une coupure de service.
INTERACTIF=${INTERACTIF:-1}
# Témoin : un redémarrage a-t-il VRAIMENT eu lieu ? La vérification qui suit n'a
# de sens qu'après — sans ce témoin, un script appelé par un autre avertissait
# « le service tourne sans le réglage » juste avant que l'appelant ne le
# redémarre. Un faux signal fait chercher une panne qui n'existe pas.
A_REDEMARRE=0

redemarrer() {
    local service="$1" cout="$2" reponse
    systemctl list-unit-files "$service.service" >/dev/null 2>&1 || return 0
    if [ "$INTERACTIF" != "1" ] || [ ! -t 0 ]; then
        jaune "$service n'est PAS redémarré (sans question)."
        dit "Quand la coupure est acceptable : sudo systemctl restart $service"
        return 0
    fi
    jaune "Redémarrer $service coupe : $cout"
    read -rp "  Redémarrer $service maintenant ? [o/N] " reponse </dev/tty || true
    if [[ "${reponse,,}" =~ ^(o|oui|y|yes)$ ]]; then
        systemctl restart "$service" && vert "$service redémarré" && A_REDEMARRE=1
    else
        jaune "$service non redémarré — le réglage ne prendra effet qu'après."
        dit "Quand la coupure est acceptable : sudo systemctl restart $service"
    fi
}

[ "$(id -u)" -eq 0 ] || { rouge "À lancer avec sudo."; exit 1; }
[ -f "$VHOST" ] || { rouge "Introuvable : $VHOST"; exit 1; }

# --- 1. Le secret partagé ----------------------------------------------------
# Un seul secret, deux endroits : la configuration Prosody et l'environnement du
# jeu. Il est fabriqué ici, jamais tapé par personne, et il ne passe par aucun
# dépôt — d'où le fichier d'environnement plutôt qu'une ligne dans l'unité
# systemd, qui est versionnée.
mkdir -p /etc/nctgame
if [ -f "$SECRET_FILE" ] && grep -q '^NCTGAME_JITSI_SECRET=' "$SECRET_FILE"; then
    SECRET="$(sed -n 's/^NCTGAME_JITSI_SECRET=//p' "$SECRET_FILE" | head -1)"
    vert "Secret déjà présent dans $SECRET_FILE — réutilisé"
else
    SECRET="$(openssl rand -hex 32)"
    cat > "$SECRET_FILE" <<EOF
# Secret partagé entre Prosody (app_secret) et le serveur de jeu.
# Fabriqué par services/jitsi/token-auth.sh. À SAUVEGARDER avec la base.
# Le changer demande de le changer DES DEUX CÔTÉS, sinon plus personne n'entre.
NCTGAME_JITSI_SECRET=$SECRET
NCTGAME_JITSI_DOMAIN=$DOM
NCTGAME_JITSI_APP_ID=$APP_ID
EOF
    chmod 600 "$SECRET_FILE"
    vert "Secret fabriqué dans $SECRET_FILE (600, root)"
fi

# --- 2. Prosody : authentification par jeton --------------------------------
if grep -qE '^\s*authentication\s*=\s*"token"' "$VHOST"; then
    vert "Prosody est déjà en authentification par jeton"
else
    SAUVE="$VHOST.avant-jeton-$(date +%Y%m%dT%H%M%S)"
    cp -a "$VHOST" "$SAUVE"
    dit "Sauvegarde : $SAUVE"

    if ! grep -qE '^\s*authentication\s*=\s*"anonymous"' "$VHOST"; then
        # On ne devine pas. Une configuration qu'on n'a pas reconnue se modifie
        # à la main : un sed approximatif sur un fichier Lua peut casser un
        # service que trois autres partagent.
        rouge "Je ne trouve pas 'authentication = \"anonymous\"' dans $VHOST."
        dit "Rien n'a été modifié. À ajouter à la main dans le VirtualHost \"$DOM\" :"
        dit "    authentication = \"token\""
        dit "    app_id = \"$APP_ID\""
        dit "    app_secret = \"<le secret de $SECRET_FILE>\""
        dit "    allow_empty_token = false"
        dit "Et dans le Component \"conference.$DOM\" : modules_enabled += \"token_verification\""
        exit 1
    fi

    # La PREMIÈRE occurrence seulement : c'est celle du VirtualHost principal.
    # Les suivantes appartiennent au domaine invité et aux composants.
    sed -i "0,/^\s*authentication\s*=\s*\"anonymous\"/s//\
        authentication = \"token\"\n\
        app_id = \"$APP_ID\"\n\
        app_secret = \"$SECRET\"\n\
        -- Faux, et c'est tout l'intérêt : 'true' laisserait entrer sans jeton,\n\
        -- ce qui rendrait ce changement décoratif.\n\
        allow_empty_token = false/" "$VHOST"
    vert "VirtualHost $DOM passé en authentification par jeton"
fi

# --- 3. Le composant MUC doit VÉRIFIER la salle -----------------------------
# Sans `token_verification` sur la salle de conférence, un jeton valable pour la
# table A ouvre la table B : la signature serait vérifiée, la revendication de
# salle ignorée. C'est la moitié qu'on oublie, et elle vaut l'autre.
if grep -qE '"token_verification"' "$VHOST"; then
    vert "Le composant de conférence vérifie déjà la salle du jeton"
else
    jaune "À ajouter à la main dans Component \"conference.$DOM\" :"
    dit "    modules_enabled = { \"token_verification\"; ... }"
    dit "Sans lui, un jeton valable pour une table ouvrirait les autres."
fi

# --- 4. Vérifier avant de redémarrer ----------------------------------------
if prosodyctl check config >/dev/null 2>&1; then
    vert "Configuration Prosody valide"
else
    rouge "prosodyctl check config échoue — RIEN N'A ÉTÉ REDÉMARRÉ."
    dit "Revenez à la sauvegarde ci-dessus, puis relisez la sortie de :"
    dit "    prosodyctl check config"
    exit 1
fi

redemarrer prosody "toutes les conférences Jitsi en cours"
redemarrer jicofo "toutes les conférences Jitsi en cours"

printf '\n'
jaune "RAPPEL : si un pare-feu Cloud existe chez l'hébergeur, l'UDP 10000 doit y"
jaune "être déclaré, pas seulement ici. Sinon la salle s'ouvre, les jetons passent,"
jaune "et personne ne s'entend — la panne la plus déroutante de cette installation."
printf '\n'
dit "Le jeu NCTGame n'utilise plus ces salles : sa parole en direct est de pair"
dit "à pair. Rien à faire de son côté après ce script."
printf '\n'
dit "Pour une salle entre humains, maintenant qu'un jeton est exigé :"
dit "  https://$DOM/<salle>?jwt=\$(python3 - <<'EOF'"
dit "import jwt, time, os"
dit "s=os.environ['NCTGAME_JITSI_SECRET']"
dit "print(jwt.encode({'iss':'$APP_ID','aud':'jitsi','sub':'$DOM','room':'*',"
dit "  'exp':int(time.time())+3600,'context':{'user':{'name':'moi'}}}, s))"
dit "EOF"
dit "  )"
