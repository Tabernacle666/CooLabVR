# CooLabVR — diagnostic automatique (2 angles, casque sur la table)

Depuis Windows, casque allumé, session OpenXR active :

```bat
diagnostic_cycle.bat
```

Le programme charge le laboratoire **Home** avec les conditions de comparaison :
- intérieur sombre (« nuit » de la scène, sans horloge jour/nuit dans cette version) et lampe allumée ;
- terminal **ambre** (thème 1), face extérieure ;
- fog activé (densité au moins 0,065) ;
- exactement **500 mouches**, même si le profil utilisateur en avait un nombre différent.

Ces valeurs sont appliquées **seulement pendant le diagnostic**, après lecture du profil, sans sauvegarder ni remplacer les réglages normaux.

## Séquence

1. Si `build/bin/Release/LaboVR.exe` manque ou si un fichier source/CMake est plus récent, `Build.ps1` lance une compilation incrémentale Release. Sinon la compilation est **ignorée**.
2. Le jeu démarre en mode `--diagnostic-sweep`. Le casque reste sur la table; le suivi OpenXR doit être actif.
3. La caméra virtuelle #1 rend l'intérieur (ampoule, ventilateur, table, brouillard) pendant **au moins trois secondes**, puis demande une capture de l'œil gauche incluant l'interface.
4. Après confirmation de la première capture, la caméra virtuelle #2 vise le panneau ambre depuis l'extérieur, rend pendant **au moins trois secondes**, puis capture.
5. Le jeu quitte de lui-même après confirmation des **deux** images ou retourne une erreur en cas d'échec/expiration. Le lanceur convertit les PNG intermédiaires issus du service OpenXR/WIC en **JPEG qualité 92**, puis supprime les PNG intermédiaires si la conversion a réussi.

Les points de vue se règlent **sans recompiler** dans `tools/diagnostic_cameras.csv`. Ils correspondent à la pièce actuelle, construite autour de Y=0..3,8 m : l'ancien CSV Y≈12 visait trop haut.

Résultats locaux dans `diagnostics/runs/<date>_<pid>/` :

```text
manifest.json
cycle.txt
LaboVR_runtime.log
LaboVR_build.log         (seulement si compilation)
capture_index.txt
diagnostic_cameras.csv
screenshots/
    01_lamp_fan_interior.jpg
    02_original_option_wall.jpg
```

Les journaux existants `vr.frame` fournissent le détail par trame; le résumé `sweep.summary` contient nombre de frames, frames suivies, frames soumises, coût CPU moyen et maximal, durée, erreurs et avertissements GPU. Le manifeste distingue `complete: true` des captures manquantes ou d'un arrêt forcé.

Le lanceur **ne fait aucun fetch, pull, commit, push ou changement de branche**. Après avoir inspecté les résultats, utiliser GitHub Desktop pour committer et pousser `diagnostics/runs/`, puis partager le résultat. Si le dépôt est public, les captures et les logs publiés seront publics.

Options : `diagnostic_cycle.bat -Seconds 90 -Parallel 8` ou `-GpuValidation`. `Seconds` (15..600) est la durée maximale de la séquence de jeu, **pas** le temps affiché par caméra (3 secondes fixes).

## Frontière XR et limites

Le diagnostic ne change que les matrices de vue/projection utilisées par le rendu (deux yeux séparés de 64 mm); **les poses de tracking OpenXR, les manettes, la simulation PhysX et les poses soumises au compositeur restent inchangées**. Les captures sont obtenues par le mécanisme hôte GPU readback déjà existant. Les vues sont destinées à la vérification visuelle, pas à un port du casque pendant la procédure.

Un casque en veille, un runtime qui refuse le rendu, une défaillance GPU ou une compilation incomplète peuvent empêcher les captures. Dans ce cas, la commande retourne un code d'échec et conserve les preuves disponibles.

**État de validation :** changements publiés au niveau source seulement. La compilation Windows/MSVC, le rendu OpenXR et le cadrage exact par rapport aux deux images de référence doivent être confirmés sur le PC du créateur; les angles CSV pourront ensuite être ajustés sans recompilation.


## Profiling leger pour optimisation future

Le balayage utilise un log compact (pas de journalisation des frames une par une).
A la fin, `sweep.summary` donne les frames demandees/suivies/soumises, le temps CPU
actif moyen et maximal et les erreurs GPU. `sweep.cpu` donne uniquement les
moyennes CPU des etapes Home, PhysX, preparation graphique, acquisition XR et
soumission graphique, ainsi que les frames dont le CPU depasse le budget
d'affichage et la periode XR moyenne. `sweep.gpu` releve une seule fois
l'adaptateur, la resolution de rendu et la VRAM utilisee/disponible.

**Important :** `submit_avg_ms` mesure le temps CPU dans la fonction de
rendu et non le temps d'execution GPU. Aucun query GPU par frame n'est ajoute.
L'option `-GpuValidation` reste facultative et peut influencer les performances.
