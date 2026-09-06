# Codex Models

Petite app macOS de barre de menus : conversations Codex locales, sous-agents
dépliables, modèles, efforts et états. Panneau compact, petite icône fixe et
filtre des éléments terminés. Aucune dépendance externe, aucun réseau, aucune
notification. Les données Codex sont ouvertes en lecture seule.

## Utiliser

Ouvrir `Codex Models.app`, puis cliquer sur l'icône dans la barre de menus.
Déplier une conversation pour voir ses sous-agents. L'activité s'actualise chaque
seconde, même quand le panneau est fermé. Le bouton Quitter ferme l'app.

Au premier lancement, l'app s'enregistre comme élément d'ouverture de session
macOS, comme Performance Viewer. Tu peux le désactiver dans Réglages Système →
Général → Ouverture et extensions.

Les conversations et les sous-agents archivés sont toujours exclus.
« Afficher les terminées » montre les éléments terminés non archivés ; le choix
est mémorisé. Un parent terminé reste visible si un de ses enfants travaille.
Les erreurs, interruptions et états inconnus restent consultables.
Les tests headless et les sessions vides sont exclus de la liste principale.

Un petit spinner orange à gauche signale une ligne en cours ; à droite, l'état
reste écrit et une coche verte accompagne « Terminé ». L'icône principale reste
fixe. Un badge numéroté signale les nouveaux sous-agents : ouvrir le panneau
l'efface. Si des sous-agents arrivent pendant la consultation, cliquer sur la
cloche dans l'en-tête pour les marquer comme vus.

## Construire et vérifier

Depuis ce dossier, sur un Mac avec les outils de développement Apple :

```sh
bash build.sh
"../Codex Models.app/Contents/MacOS/CodexModels" --check
bash Scripts/install-to-applications.sh
```

La compilation crée une app signée localement à côté de ce dossier. Il n'y a pas
d'installation ni de démarrage automatique. La signature locale convient à ce
Mac ; elle n'est pas une notarisation Apple pour distribuer l'app à d'autres Macs.

L'option `--preview` ouvre la même interface dans une fenêtre de test.
Le script `Scripts/install-to-applications.sh` copie le bundle dans `/Applications`
et le lance, ce qui le rend facilement trouvable par Spotlight.
Le panneau utilise le même `MenuBarExtra` natif que Performance Viewer : macOS
gère sa position sous l'icône et son redimensionnement. Sa largeur est de 330
points ; les lignes de 44 points restent entièrement visibles et la liste devient
défilante au-delà de 300 points.
L'icône originale est fournie dans `Resources/AppIcon.icns` ; son générateur
AppKit est dans `Scripts/MakeIcon.swift` (argument : dossier `.iconset` de sortie,
puis conversion par `iconutil -c icns`).

## Ce que l'affichage prouve

Le modèle et l'effort sont ceux enregistrés par Codex pour chaque conversation.
Ce n'est pas une certification du modèle exécuté côté serveur. L'état est celui
du dernier tour enregistré ; après un arrêt brutal de Codex, il peut rester
« En cours ». Un champ absent est indiqué explicitement, jamais déduit du parent.

Voir [les données et la vérification](docs/architecture.md).
