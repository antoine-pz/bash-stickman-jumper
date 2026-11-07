#!/bin/bash

if [[ -z "$TMUX" ]]; then
	echo "First start tmux (sudo apt install tmux)"
	exit 1
fi

LIGNES=$(tput lines)
COLONNES=$(tput cols)

PAS_TEMPS=100000         #=0,1s correspond a un tick dans le jeu
FORCE_SAUT=3
GRAVITE=1		 #augmente la vitesse vers le bas de 1 a chaque tick

SOL=$((LIGNES - 4))      #ligne du haut du bonhomme quand il est sur le sol (recalculee quand on saute sur une ligne)
plancher=$LIGNES         #ligne ou est trace le sol
curseur_y=0              #ligne du curseur au debut
pret=0                   #passe a 1 quand le terminal est reconstruit

x=$((COLONNES / 2 - 1))  #colonne du coin haut gauche du bonhomme
y=$SOL                   #ligne du coin haut gauche du bonhomme
vx=0                     #vitesse horizontale (utilisee en l'air)
vy=0                     #vitesse verticale (negatif = haut, positif = bas)
dir=0                    #derniere direction pressee (-1 pour gauche, 0 pour rien, 1 pour droite)
dir_restant=0            #nombre de ticks avant d'oublier dir
ancien_x=$x
ancien_y=$y

#carte["ligne,colonne"]=caractere
declare -A carte

#va a (ligne, colonne), en comptant a partir de 0
aller() {
	local ligne=$1
	local colonne=$2
	printf '\e[%d;%dH' $((ligne+1)) $((colonne+1))
}

#efface le bonhomme en redessinant le decor qui etait dessous
effacer() {
	local i j ligne
	for i in 0 1 2; do
		ligne=""
		for j in 0 1 2; do
			ligne+="${carte[$((ancien_y + i)),$((ancien_x + j))]:- }"
		done
		aller $((ancien_y+i)) "$ancien_x"
		printf '%s' "$ligne"
	done
}

#remet le terminal en etat a la sortie
#on enleve seulement le bonhomme et le sol
restaurer() {
	if ((pret)); then
		effacer
		((plancher<LIGNES)) && { aller "$plancher" 0; printf '\e[2K'; }	#2 choisit toute la ligne et K l'efface
	fi
	tput cnorm		#reaffiche le curseur
	stty echo		#reactive echo
	aller "$curseur_y" 0	#repositionne le curseur sur sa position de depart
}
trap restaurer EXIT		#execute la fonction restaurer des qu'on quitte (a ou ctrl+c)

borner_x() {
	((x<0)) && x=0
	((x>COLONNES-4)) && x=$((COLONNES-4))
}

#vrai si une case solide se trouve sous les pieds
sur_support() {
	local j
	for j in 0 1 2; do
		[[ -n "${carte[$((y+3)),$((x+j))]}" ]] && return 0
	done
	return 1
}

#vrai si le bonhomme n'est pas pose
en_l_air() {
	((vy!=0)) || (! sur_support)
}

#lit l'ecran reel de tmux et remplit la carte
capturer_decor() {
	local texte l c ligne car s
	mapfile -t texte < <(tmux capture-pane -p -t "$TMUX_PANE")

	for ((l = 0; l < ${#texte[@]} && l < LIGNES; l++)); do
		ligne=${texte[l]}
		for ((c = 0; c < ${#ligne} && c < COLONNES; c++)); do
			car=${ligne:c:1}
			[[ "$car" != " " ]] && carte[$l,$c]=$car
		done
	done

	#le sol : 4 lignes sous le curseur, ou en bas de l'ecran (pour pouvoir sauter et atteindre la premiere ligne sinon c'est pas fun)
	plancher=$((curseur_y+4))
	((plancher > LIGNES)) && plancher=$LIGNES
	for ((c = 0; c < COLONNES; c++)); do
		carte[$plancher,$c]="="
	done

	#on le dessine seulement s'il est visible
	if ((plancher < LIGNES)); then
		printf -v s '%*s' $((COLONNES - 1)) ''
		aller "$plancher" 0
		printf '%s' "${s// /=}"
	fi

	#le bonhomme demarre pose sur le sol
	SOL=$((plancher-3))
	y=$SOL
	ancien_y=$y
	pret=1
}

dessiner() {
	printf '\e[31m'		#active la couleur rouge pour le bonhomme
	aller "$y" $((x + 1));          printf 'o'
	aller $((y + 1)) "$x";          printf '/|\\'
	aller $((y + 2)) "$x";          printf '/'
	aller $((y + 2)) $((x + 2));    printf '\\'
	printf '\e[0m' 		#remet la couleur noire de base
}

#appui sur q (-1) ou d (1)
deplacer() {
	local direction=$1
	dir=$direction
	dir_restant=3
	if en_l_air; then
		vx=$direction             #en l'air : on oriente le saut
	else
		x=$((x+2*direction))  	  #au sol : on avance de 2 colonnes
		borner_x
	fi
}

#un tick de physique
physique() {
	local n

	#on oublie la direction memorisee apres 3 ticks
	if ((dir_restant > 0)); then
		((dir_restant--))
		((dir_restant == 0)) && dir=0
	fi

	#deplacement horizontal (non nul seulement en l'air)
	if ((vx!=0)); then
		x=$((x+vx))
		borner_x
	fi

	#deplacement vertical, une case a la fois
	if ((vy<0)); then
		for ((n = 0; n < -vy; n++)); do
			((y > 0)) && ((y--))       #en montant, on traverse les lignes
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
	fi
}

stty -echo			#on enleve echo pour ne pas avoir de caracteres parasites
tput civis
curseur_y=$(tmux display-message -p -t "$TMUX_PANE" '#{cursor_y}')
capturer_decor
dessiner
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

	#on redessine seulement si le bonhomme a bouge
	if ((x != ancien_x || y != ancien_y)); then
		effacer
		dessiner
		ancien_x=$x
		ancien_y=$y
	fi
done
