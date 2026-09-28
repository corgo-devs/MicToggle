# MicToggle

Petite app macOS native pour couper et réactiver le microphone depuis un raccourci global ou la barre des menus, sans chercher la fenêtre de Slack ou d’une autre app. Elle agit sur le micro d’entrée par défaut de macOS, sans enregistrer de son et sans Rosetta.

## Fonctionnalités

- Raccourci clavier global personnalisable.
- Pastille dans la barre des menus : rouge = muet, verte = actif, grise = indisponible.
- Indicateur temporaire ON/OFF avec icône de micro et niveau d’entrée en pourcentage.
- Restauration du niveau précédent pour chaque microphone.
- Affichage de la source et option de lancement à la connexion.

## Compiler et lancer

Prérequis : **Mac Apple Silicon**, **macOS 13 ou plus**, et outils de ligne de commande Xcode (`xcode-select --install` si nécessaire).

Dans le dossier du projet :

```sh
chmod +x build.sh
./build.sh
open MicToggle.app
```

Le script génère `MicToggle.app` et `MicToggle.zip`. Il applique une signature locale **ad hoc**, sans compte développeur Apple. L’app n’est pas signée avec Developer ID ni notarisée : les fichiers compilés ne sont pas inclus dans le dépôt.

## Utilisation

- **Clic gauche** sur la pastille : couper ou réactiver le micro.
- **Clic droit** : afficher la source et le niveau, choisir un raccourci ou quitter.
- Raccourci initial : **⌘F5**. Comme macOS l’utilise aussi pour VoiceOver, choisir une autre combinaison si nécessaire, par exemple **⌃⌥M**. F5 peut nécessiter la touche Fn.

## À savoir

Le mute règle le volume d’entrée à 0, ou utilise la commande mute du périphérique si le volume n’est pas modifiable. Certains micros ne permettent aucun des deux.

Seule la source d’entrée par défaut de macOS est concernée : une app utilisant un autre micro n’est pas affectée. 

Diagnostic en lecture seule :

```sh
MicToggle.app/Contents/MacOS/MicToggle --status
```
