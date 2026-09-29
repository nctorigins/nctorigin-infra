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

# --- Le relais, qui sert au jeu ----------------------------------------------
# `coturn` est posé par l'installation Jitsi, et il sert à quelqu'un d'autre : la
# parole en direct de NCTGame, qui est de pair à pair et n'utilise AUCUNE salle
# Jitsi. Elle ne lui demande qu'un secours pour les réseaux qui refusent le
# direct, avec des identifiants temporaires calculés depuis le secret que coturn
# vérifie déjà (`use-auth-secret`).
#
# Le jeu ne peut pas lire /etc/turnserver.conf (il ne tourne pas en root) : le
# secret doit lui être recopié. C'EST FAIT ICI, ET PAS À LA MAIN.
#
# POURQUOI ICI, et pas dans l'installation du jeu : l'ordre des services est
# `nctgame, quran, whisper, jitsi`, donc `coturn` n'existe pas encore quand le jeu
# s'installe. Il n'y a qu'un seul moment où le secret est disponible, et c'est
# celui-là.
#
# ET POURQUOI AUTOMATIQUEMENT : une commande à lancer à la main est une commande
# qu'on oublie sur la machine suivante. Une installation complète doit rendre un
# service complet, sans laisser une fonction éteinte derrière un avertissement que
# personne ne relit.
SECRET_RELAIS="$ICI/services/nctgame/turn-secret.sh"
if ! grep -qE '^static-auth-secret=' /etc/turnserver.conf 2>/dev/null; then
    alerte "coturn absent ou sans secret partagé : la parole en direct du jeu"
    alerte "répondra live_voice_not_configured. Relancez ce bootstrap après"
    alerte "l'installation de Jitsi, ou posez-le avec :"
    info "  sudo bash services/nctgame/turn-secret.sh"
elif [ ! -x "$SECRET_RELAIS" ] && [ ! -f "$SECRET_RELAIS" ]; then
    alerte "Script introuvable : $SECRET_RELAIS"
else
    # `INTERACTIF=0` : le script ne POSE PAS la question du redémarrage, et n'en
    # fait aucun. C'est à l'installation de décider, juste en dessous — un script
    # appelé par un autre ne doit pas décider d'une coupure de service.
    # `|| alerte` : avec `set -euo pipefail`, un échec de ce script auxiliaire
    # ferait avorter TOUTE l'installation du service. Une fonction facultative qui
    # tombe ne doit pas emporter le reste — c'est la même règle que le tiret devant
    # l'EnvironmentFile de l'unité.
    INTERACTIF=0 bash "$SECRET_RELAIS" 2>&1 | sed 's/^/  /' \
        || alerte "Le secret du relais n'a pas pu être posé : parole en direct éteinte"
    if [ -s /etc/nctgame/live-voice.env ]; then
        ok "Secret du relais posé pour la parole en direct du jeu"
        # Le jeu a été installé AVANT coturn, donc il tourne sans ce secret : il
        # faut le relire. Défaut OUI ici et non ailleurs, parce qu'on est au
        # milieu d'une installation — le service vient d'être redémarré quelques
        # étapes plus haut, et laisser la fonction éteinte serait le pire des deux.
        if systemctl is-active --quiet nctgame 2>/dev/null; then
            if demande_oui_non "Redémarrer nctgame pour qu'il lise le secret du relais ? (coupe les parties en cours)" o; then
                systemctl restart nctgame && ok "nctgame redémarré"
            else
                alerte "La parole en direct restera éteinte jusqu'au prochain"
                alerte "redémarrage : sudo systemctl restart nctgame"
            fi
        fi
    fi
fi
