#!/usr/bin/env bash
# jitsi — visioconférence Jitsi Meet.
#
# Ce module est le plus court des quatre, et il le restera : Jitsi ne
# s'installe pas comme les autres. Ce n'est pas un dépôt qu'on clone et un venv
# qu'on remplit, c'est une suite de paquets Debian (prosody, jicofo,
# jitsi-videobridge2, coturn) posés par un script qui existe déjà et qui est
# éprouvé. Le réécrire ici en donnerait une seconde version, et ce répertoire
# vient précisément d'en archiver six.

S=jitsi
DIR="/home/$APP_USER/jitsi-installation"
DOM="${DOMAINE[$S]}"
SCRIPT="$DIR/jitsi-installation-enhanced-v3.1-safe.sh"

depot "https://github.com/nctorigins/jitsi-installation.git" "$DIR" "$APP_USER"

if systemctl is-active --quiet jicofo 2>/dev/null; then
    ok "Jitsi déjà installé et actif — rien à refaire"
    info "Pour le réinstaller : $SCRIPT"
    info "Pour le retirer     : $DIR/jitsi-uninstall.sh"
else
    [ -x "$SCRIPT" ] || chmod +x "$SCRIPT" 2>/dev/null || true
    attends_dns "$DOM" || alerte "Jitsi refusera de s'installer sans DNS"

    printf '\n'
    alerte "TROIS CHOSES QUE CE SCRIPT NE PEUT PAS FAIRE POUR VOUS :"
    printf '\n'
    info "1. Ouvrir l'UDP 10000 dans le pare-feu de HETZNER — la console de"
    info "   l'hébergeur, pas cette machine. Sans lui, tout paraîtra correct"
    info "   et la vidéo ne passera pas. C'est la panne la plus déroutante de"
    info "   cette installation."
    printf '\n'
    info "2. Répondre à debconf. Le paquet demande jitsi-meet/jvb-hostname"
    info "   AVANT tout le reste, et une réponse erronée s'installe sans"
    info "   qu'on la revoie. Répondez : $DOM"
    printf '\n'
    info "3. Choisir de continuer. L'installation touche nginx et les"
    info "   certificats, que trois autres services partagent."
    printf '\n'

    if demande_oui_non "Lancer l'installation de Jitsi maintenant ?" n; then
        # La v3.1-safe, et elle seule : c'est la seule des sept versions
        # archivées qui se sache sur une machine déjà occupée. Les autres
        # réécriraient la configuration nginx des trois autres services.
        bash "$SCRIPT"
    else
        info "Jitsi non installé. Quand vous voudrez :"
        info "  sudo bash $SCRIPT"
    fi
fi

ouvre_ports 10000/udp 3478/udp 5349/tcp
alerte "Rappel : ces ports doivent AUSSI être ouverts côté Hetzner."
