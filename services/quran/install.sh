#!/usr/bin/env bash
# quran-recognizer — reconnaissance de récitation coranique.
#
# Sourcé par bootstrap.sh, qui a déjà posé le socle. Toutes les fonctions
# viennent de lib/common.sh.

S=quran
DIR="/home/$APP_USER/quran_recognizer"
DOM="${DOMAINE[$S]}"
PRT="${PORT[$S]}"
UNI="${UNITE[$S]}"

depot "https://github.com/nctorigins/quran_recognizer.git" "$DIR" "$APP_USER"
venv_python "$DIR" "$APP_USER"

# Le texte uthmani voyage AVEC le dépôt : api.py le lit au démarrage, et une
# donnée dont le code dépend n'a pas sa place sur une seule machine. Rien à
# télécharger ici, donc — c'est ce qui distingue ce service de nctgame, dont la
# base d'adresses ne peut pas être versionnée.
if [ -f "$DIR/data/quran_uthmani.txt" ]; then
    ok "texte uthmani présent"
else
    alerte "data/quran_uthmani.txt manquant — /track-text ne fonctionnera pas."
    alerte "Il est versionné : un dépôt à jour devrait le porter."
fi

pose_unite "$ICI/services/$S/service.service" "$UNI" "$DIR" "$APP_USER"
attends_dns "$DOM" || alerte "on continue, mais le certificat va probablement échouer"
pose_nginx "$ICI/services/$S/nginx.conf" "$DOM" "$PRT"
pose_certificat "$DOM" "$COURRIEL"

sleep 1
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://$DOM/" 2>/dev/null || echo 000)
case "$code" in
    200|404|405) ok "https://$DOM répond ($code)" ;;
    *)           alerte "https://$DOM répond $code" ;;
esac
