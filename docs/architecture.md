# Données locales et invariants

## Source

L'app lit deux bases SQLite dans le dossier Codex local :

- `state_5.sqlite` : `threads` pour le nom, le modèle et l'effort ;
  `thread_spawn_edges` pour les liens parent-enfant.
- `thread_history_1.sqlite` : dernier `thread_turns` par `rollout_ordinal`, pour
  l'état `inProgress`, `completed`, `interrupted` ou `failed`.
- Pour les conversations `legacy`, `session_index.jsonl` fournit le dernier nom
  si `threads.name` est vide. Sans tour dans la nouvelle table, le dernier événement
  de cycle de vie du journal (`task_started`, `task_complete`, `turn_aborted`,
  `task_failed`) fournit l'état. Le journal est parcouru depuis la fin par blocs
  de 64 Kio ; le lecteur s'arrête au premier événement reconnu.

Ces schémas privés ont été vérifiés sur Codex CLI 0.153.4, app 26.901.41600.
Une évolution incompatible doit afficher une erreur explicite ; ne pas inventer
des données ni prendre la configuration globale comme modèle d'un enfant.
L'absence de la base d'historique donne un état inconnu.

Les connexions utilisent `SQLITE_OPEN_READONLY` et un délai d'attente court.
Une transaction de lecture regroupe les noms et les liens pour obtenir un arbre
cohérent. Les modèles proviennent des métadonnées. Pour les anciens journaux,
seuls les événements de cycle de vie sont exploités : les messages ne sont ni
affichés ni enregistrés. Les titres peuvent contenir le texte choisi par Codex.
Aucune donnée n'est exportée, stockée par l'app ou envoyée sur le réseau.

## Affichage

Les conversations interactives (`source=vscode` ou `cli`), non archivées et ayant
un nom ou un titre, sont triées par récence. Les exécutions headless (`exec`) et
les sessions encore vides ne polluent pas la liste. Ce filtre de source porte
uniquement sur les racines. Le filtre d'archivage porte sur tous les niveaux :
une conversation archivée et ses descendants ne sont jamais affichés.
Le nom explicite a priorité
sur le titre initial. Pour un enfant sans nom, le dernier segment d'`agent_path`
sert de libellé. Les descendants sont dépliables, y compris sur plusieurs niveaux.
Un cycle de liens est coupé au parcours, sans boucle infinie.

L'arête `status=open` signifie que l'enfant reste ouvert, pas qu'il travaille :
elle n'intervient jamais dans l'état affiché. Seul le dernier tour enregistré
détermine cet état. Après un crash, cet enregistrement peut être périmé ; l'app
ne tente pas de déduire l'activité à partir d'une date ou d'un nom de modèle.

Le chargement s'effectue en arrière-plan sur une file série. L'app rafraîchit
les données chaque seconde, dès son lancement et même lorsque le panneau est
fermé. Une lecture déjà en cours empêche l'empilement de requêtes. Seul un arbre
modifié est republié, pour préserver les dépliages et ne pas rejouer les animations.
Les champs modèle/effort absents sont affichés « Non fourni ».

Le filtre « Afficher les terminées » est mémorisé localement. Quand il est éteint,
les feuilles `completed` disparaissent ; leur parent reste visible si un autre
descendant est encore consultable. Les archives restent exclues dans les deux cas.
Le compteur d'activité additionne les tours `inProgress` de l'arbre non archivé,
indépendamment du filtre. Il ne représente ni un quota ni un pourcentage d'avancement.

La présentation est volontairement minimale : fond sombre, lignes compactes et
icône principale monochrome fixe. Les lignes en cours ont un spinner orange de
9 points à gauche ; « Terminé » est accompagné d'une coche verte à droite.
Le spinner devient statique lorsque macOS demande une réduction des animations.
Le dépliage et le filtrage utilisent une transition courte.

## Nouveaux sous-agents

Le premier relevé réussi initialise les identifiants connus sans créer de badge.
Les relevés suivants comptent les nouveaux descendants dont la date de création
est postérieure au démarrage du suivi (`created_at_ms`, ou `created_at` en repli).
Le retour d'une vieille conversation ne constitue donc pas un nouveau lancement.
Les identifiants déjà vus sont conservés pour éviter de recompter un même agent.

La cloche et son nombre apparaissent dans le libellé natif de la barre de menus.
L'ouverture du panneau et son retour au premier plan acquittent le badge ; une
cloche cliquable dans l'en-tête permet aussi d'acquitter des arrivées pendant la
consultation. Les éléments archivés sont retirés du badge. L'acquittement ne
modifie ni les conversations ni leur archivage. Ce compteur n'est pas persistant :
un redémarrage recommence sur une base vide. Aucune notification système n'est émise.

## Positionnement natif

Le mécanisme reprend celui de
[Performance Viewer](https://github.com/sanztheo/PerformanceViewer/blob/da96cbe133bcfceaa6bf7a769128f91860d28dc1/Performance/PerformanceApp.swift) :
`MenuBarExtra` avec `.menuBarExtraStyle(.window)`. Le système possède l'ancrage,
le placement et le redimensionnement de la fenêtre. Aucun `NSStatusItem`,
`NSPopover` ou calcul de coordonnées ne reste dans Codex Models.

Comme dans `MenuBarPopover.swift` de Performance Viewer, seule la largeur globale
est fixée (330 points). Chaque ligne fait exactement 44 points ; la liste réserve
cette hauteur pour chaque élément déplié, puis devient défilante au-delà de
300 points. La fenêtre native déduit sa taille de cette vue, sans synchronisation
manuelle avec un contrôleur AppKit.

Cette migration supprime le décalage entre les dimensions du popover manuel et
celles de la vue hébergée, qui pouvait pousser le panneau hors écran ou couper
des lignes. Les anciens contrôles `--open-panel` et `--check-panel`, liés à ce
popover manuel, sont supprimés. Le suivi des données reste indépendant de
l'ouverture du panneau.

## Vérification

`--check` crée des bases temporaires et vérifie la hiérarchie, le titre renommé,
le modèle et l'effort propres à l'enfant, le passage en cours → terminé malgré
une arête toujours ouverte, l'exclusion des racines et enfants archivés, le filtre
des éléments terminés avec conservation d'un parent d'enfant actif, l'état manquant
et le refus effectif d'une écriture par le lecteur SQLite.
Il vérifie également le badge `0 → 4 → 0 → 1 → 0`, l'absence de doublons,
l'exclusion de l'historique, l'acquittement et le retrait des archives.
Le cas ancien vérifie un renommage successif dans l'index et un événement de fin
retrouvé au-delà d'une frontière de bloc, puis son exclusion par le filtre des
terminées. Un état inconnu reste affiché comme tel, sans être assimilé à une fin.

Le test réel consiste à observer un enfant de cette conversation en cours puis
terminé, en comparant les valeurs affichées avec les mêmes métadonnées locales.
L'affichage ne dépend pas du hook `SubagentStart`, dont les événements n'étaient
pas correctement rendus par l'app Codex lors du test précédent.
Ce hook expérimental, sa déclaration et son état de confiance ont été retirés
après remplacement par l'app. Les autres hooks restent inchangés.

Validation réelle : `test_hook_luna` sous la conversation de construction a été
lu en `gpt-5.6-luna`, effort `max`, d'abord `running` puis `completed`. Son parent
est enregistré en `gpt-6-astra`, effort `high`. Le dépliage de la vue SwiftUI a
été vérifié par l'interface d'accessibilité et visuellement sur les vraies données.

Interface native SwiftUI ; `LSUIElement` masque l'icône du Dock.

Le 6 septembre 2026, la vue native a été vérifiée sur les données locales : les
trois conversations tiennent entièrement dans la fenêtre ; déplier l'enfant Luna
agrandit la fenêtre et affiche les quatre lignes sans en couper une. Le contrôle
`--check` et la vérification de signature passent après migration.
