#!/bin/bash

if [[ -z "$TMUX" ]]; then
	echo "First start tmux (sudo apt install tmux)"
	exit 1
fi

LIGNES=$(tput lines)
COLONNES=$(tput cols)

PAS_TEMPS=100000         #=0,1s correspond a un tick dans le jeu
FORCE_SAUT=3
GRAVITE=1                #augmente la vitesse vers le bas de 1 a chaque tick
VITESSE_CHUTE_MAX=4      #vitesse de chute maximale (pour que la camera suive bien)
MARGE=5                  #distance minimale entre le bonhomme et le haut/bas de l'ecran

hist=0                   #nombre de lignes d'historique (=num ligne 1 de l'ecran d'origine)
curseur_y=0              #ligne du curseur sur l'ecran d'origine
plancher=0               #numero (dans le monde) de la ligne qui sert de sol
camera=0                 #numero (dans le monde) de la ligne affichee tout en haut de l'ecran
LIGNE_SOL=""             #le sol, qui est une ligne de "="
pret=0                   #passe a 1 quand on est sur l'ecran alternatif

x=$((COLONNES / 2 - 1))  #colonne du coin haut gauche du bonhomme
y=0                      #ligne du coin haut gauche du bonhomme (dans le monde)
vx=0                     #vitesse horizontale (utilisee en l'air)
vy=0                     #vitesse verticale (negatif = haut, positif = bas)
dir=0                    #derniere direction pressee (-1 pour gauche, 0 pour rien, 1 pour droite)
dir_restant=0            #nombre de ticks avant d'oublier dir
ancien_x=$x
ancien_y=$y
ancien_camera=0
car=" "                  #resultat de lire_case

#monde[ligne]="texte de la ligne"
monde=()

#va a (ligne d'ecran, colonne), en comptant a partir de 0
aller() {
	printf '\e[%d;%dH' $(($1 + 1)) $(($2 + 1))
}

# ecrit un texte a (ligne du MONDE, colonne), seulement si la ligne est visible
ecrire() {
	local l=$1 c=$2 contenu_a_afficher=$3
    	local r=$((l-camera))
    	if ((r>=0 && r<LIGNES)); then
        	aller "$r" "$c"
        	printf '%s' "$contenu_a_afficher"
    	fi
}

#met dans $car le caractere du monde a (ligne, colonne)
lire_case() {
    	local l=$1 c=$2
    	car=" "
    	if ((l==plancher)); then
        	car="="
    	elif ((l>=0&&l<${#monde[@]})); then
        	car=${monde[l]:c:1}
        	[[ -z "$car" ]] && car=" "
    	fi
}

# vrai si la case (ligne, colonne) est solide
solide() {
    	local l=$1 c=$2
    	((l>=plancher)) && return 0
    	((l<0)) && return 1
    	lire_case "$l" "$c"
    	[[ "$car" != " " ]]
}

#remet le terminal en etat a la sortie : l'ecran alternatif disparait
#et le vrai terminal (tmux) revient exactement comme avant
restaurer() {
	((pret)) && tput rmcup
    	tput cnorm		#reaffiche le curseur
    	stty echo		#reactive echo
}
trap restaurer EXIT	#execute la fonction restaurer des qu'on quitte (a ou ctrl+c)

borner_x() {
    	((x<0)) && x=0
    	((x>COLONNES-4)) && x=$((COLONNES-4))
}

#vrai si une case solide se trouve sous les pieds
sur_support() {
    	local j
    	for j in 0 1 2; do
        	solide $((y+3)) $((x+j)) && return 0	#la fonction solide verifie si on est sur un car
    	done
    	return 1
}

#vrai si le bonhomme n'est pas pose
en_l_air() {
    	((vy!=0)) || ! sur_support
}

#lit tout l'historique de tmux + l'ecran, et prepare le monde
capturer_monde() {
    	local infos
    	infos=$(tmux display-message -p -t "$TMUX_PANE" '#{history_size} #{cursor_y}')
    	hist=${infos% *}
    	curseur_y=${infos#* }

    	#-S - <=> depuis le debut de l'historique
    	mapfile -t monde < <(tmux capture-pane -p -S - -t "$TMUX_PANE")

    	#le sol est 4 lignes sous le curseur ou juste sous la derniere ligne de l'ecran
    	plancher=$((hist + curseur_y + 4))
    	((plancher>hist+LIGNES)) && plancher=$((hist + LIGNES))

    	printf -v LIGNE_SOL '%*s' $((COLONNES - 1)) ''
    	LIGNE_SOL=${LIGNE_SOL// /=}

    	#le bonhomme demarre pose sur le sol et la camera sur l'ecran d'origine
    	y=$((plancher - 3))
    	ancien_y=$y
    	camera=$hist
    	ancien_camera=$camera
}

#redessine tout l'ecran d'un coup (des que la camera bouge)
afficher_tout() {
    	local r l ligne buf=""
    	
    	for ((r = 0; r < LIGNES; r++)); do		#pour chaque ligne de l'ecran
        l=$((camera + r))			#numero de la ligne dans le monde
        if ((l==plancher)); then
            ligne=$LIGNE_SOL
        elif ((l<${#monde[@]})); then		#@ pour tous les elements du tableau et # pour len()
            ligne=${monde[l]:0:COLONNES-1}	#en bash variable:debut:longueur_max
        else
            ligne=""
        fi
        
        buf+=$'\e['$((r+1))$';1H'"$ligne"$'\e[K'	#buffer d'affichage
    	done
    	printf '%s' "$buf"
    	dessiner
}

dessiner() {
    	printf '\e[31m'        #active la couleur rouge pour le bonhomme
    	ecrire "$y" $((x + 1)) 'o'
    	ecrire $((y + 1)) "$x" '/|\'
    	ecrire $((y + 2)) "$x" '/'
    	ecrire $((y + 2)) $((x + 2)) '\'
    	printf '\e[0m'         #remet la couleur noire de base
}

#efface le bonhomme en redessinant le decor qui etait dessous
effacer() {
    	local i j ligne
    	for i in 0 1 2; do
        	ligne=""
        	for j in 0 1 2; do
            		lire_case $((ancien_y + i)) $((ancien_x + j))
            		ligne+=$car
        	done
        	ecrire $((ancien_y + i)) "$ancien_x" "$ligne"
    	done
}

#deplace la camera si le bonhomme s'approche du haut ou du bas de l'ecran
suivre_camera() {
    	local cible=$camera
    	((y-cible < MARGE)) && cible=$((y-MARGE))	#si le bonhomme depasse la MARGE, on remonte la camera
    	((y+2 - cible > LIGNES-1-MARGE)) && cible=$((y+2 - (LIGNES-1-MARGE)))	#si le bonhomme tombe sous la marge, on descend la camera
    	((cible<0)) && cible=0		#securite pour le haut
    	((cible>hist)) && cible=$hist	#securite pour le bas
    	camera=$cible			#on applique le changement
}

# appui sur q (-1) ou d (1)
deplacer() {
    	local direction=$1
    	dir=$direction
    	dir_restant=3
    	if en_l_air; then
        	vx=$direction          	#en l'air : on oriente le saut
    	else
        	x=$((x+2*direction))	#au sol : on avance de 2 colonnes
        	borner_x
    	fi
}

#un tick de physique
physique() {
    	local n

    	#on oublie la direction memorisee apres 3 ticks
    	if ((dir_restant>0)); then
        	((dir_restant--))
        	((dir_restant==0)) && dir=0
    	fi

    	#deplacement horizontal (non nul seulement en l'air)
    	if ((vx!=0)); then
        	x=$((x + vx))
        	borner_x
    	fi

    	#deplacement vertical, une case a la fois
    	if ((vy<0)); then
        	for ((n = 0; n < -vy; n++)); do
            		((y>0)) && ((y--))       #en montant, on traverse les lignes
        	done
    	elif ((vy>0)); then
        	for ((n = 0; n < vy; n++)); do
            		sur_support && break       #on s'arrete sur le premier support
            		((y++))
        	done
    	fi

    	#atterrissage ou gravite
    	if ((vy>=0)) && sur_support; then
        	vy=0
        	vx=0
    	else
        	vy=$((vy+GRAVITE))
        	((vy>VITESSE_CHUTE_MAX)) && vy=$VITESSE_CHUTE_MAX	#on gap la vitesse de chute
    	fi
}

stty -echo            #on enleve echo pour ne pas avoir de caracteres parasites
capturer_monde        #il faut capturer AVANT de passer sur l'ecran alternatif
tput smcup            #ecran alternatif : le terminal d'origine est preserve
pret=1
tput civis
afficher_tout
dernier=${EPOCHREALTIME//[.,]/}    #heure actuelle en microsecondes

while true; do
    	#attend une touche 0,03s au maximum
    	IFS= read -rsn1 -t 0.03 touche || touche=""

    	case "$touche" in
        	q) deplacer -1 ;;
        	d) deplacer 1 ;;
        	" ") en_l_air || { vy=$((-FORCE_SAUT)); vx=$dir; } ;;
        	a) break ;;
    	esac

    	#la physique avance seulement si 0,1s s'est ecoulee
    	maintenant=${EPOCHREALTIME//[.,]/}
    	if ((maintenant-dernier>=PAS_TEMPS)); then
    	    physique
    	    dernier=$maintenant
    	fi

    	suivre_camera

    	if ((camera!=ancien_camera)); then
        	#la camera a bouge : on redessine tout l'ecran
        	afficher_tout
        	ancien_camera=$camera
        	ancien_x=$x
        	ancien_y=$y
    	elif ((x!=ancien_x || y!=ancien_y)); then
    		#sinon on redessine seulement le bonhomme
    	    	effacer
    	    	dessiner
   	     	ancien_x=$x
   	     	ancien_y=$y
   	fi
done
