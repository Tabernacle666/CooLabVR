# ConsoleVR — cycle de trois caméras virtuelles (casque immobile)

Commande depuis `ConsoleVR` sous Windows avec le casque allumé et une session OpenXR active :

```bat
diagnostic_cycle.bat
```

Le casque **reste sur la table** : aucune rotation, translation, ni marche de l'utilisateur n'est requise. Le rendu 3D est automatiquement pris à **trois positions virtuelles à des hauteurs différentes**, avec leurs cibles propres et leur perspective stéréo.

## Trois points de vue configurables

Fichier `tools/diagnostic_cameras.csv` (les 3 entrées sont éditables sans recompiler ; le fichier est copié dans chaque dossier de résultats) :

```csv
name,x,y,z,target_x,target_y,target_z
lab_exterior,13,16,-13,0,12,0
original_option_wall,0,12,7.5,0,11.875,3.96
lamp_fan_interior,-2.5,12.8,0.0,-0.85,12.2,1.15
```

Coordonnées en mètres du World (Y vertical). Après 1,1 seconde de stabilisation par position, Core demande au service hôte de capturer l'œil gauche. La suivante est sélectionnée **après confirmation PNG enregistré** ; en cas d'échec, trois tentatives maximum par point de vue. Les noms sont `01_lab_exterior.png`, `02_original_option_wall.png`, `03_lamp_fan_interior.png` si les trois captures réussissent.

## Frontière de l'ABI et intégrité OpenXR

Le mode est uniquement activé par `--diagnostic-sweep`. Dans Core, la caméra virtuelle modifie exclusivement `XRFrame.vp`, `XRFrame.inverseVP` et `XRFrame.eyes`, utilisés par le moteur graphique. **`xrLocateViews`, les actions, les coordonnées physiques des contrôleurs, la simulation, les informations publiées aux cartouches et les poses OpenXR de `xrEndFrame` ne sont pas falsifiées.** La capture GPU/WIC utilise le mécanisme hôte déjà existant.

Les cartouches ne lisent jamais la swapchain. Le repère temporaire à **(0,Y,0), de Y=0 à Y=4 m** est produit par le WorldEditor et ses services visuels existants, sans collision ni sauvegarde. Une exécution normale de `run.bat` n'active ni le repère ni les vues virtuelles.

Comme les poses utilisées pour le rendu de diagnostic diffèrent des poses physiques présentées au compositeur OpenXR, **ces images sont destinées aux PNG du diagnostic et non à un affichage confortable dans un casque porté**.

## Cycle automatisé

Le batch appelle `tools/DiagnosticCycle.ps1` :

1. Vérification des modifications Git locales, puis `git fetch` et `git pull --ff-only origin dev`.
2. Compilation complète Release avec `tools/Build.ps1`.
3. Exécution de `LaboVR.exe --diagnostic-sweep 100 --diagnostic-camera-file "…\diagnostic_cameras.csv"`.
4. Captures automatiques, fichiers PNG nommés, logs du runtime et du build, `manifest.json`, `capture_index.txt`, positions CSV et `cycle.txt`.
5. Commit et push **uniquement** du dossier `diagnostics/runs/<session>/` sur `dev`. Aucun reset ni push forcé. Si le build ou le run échoue, les preuves disponibles sont quand même enregistrées.

Options : `diagnostic_cycle.bat -Seconds 120 -Parallel 8` et `-GpuValidation`.

Le cycle se termine dès que les trois captures sont enregistrées ou à expiration du délai prévu. Une expiration supplémentaire du processus protège contre un blocage de la fermeture de laboratoire.

**Conditions réelles :** le casque doit être reconnu par OpenXR, la session doit produire des vues valides et le moteur doit afficher les scènes. Le programme ne peut pas générer une capture correcte si la session XR ne fournit plus de rendu (veille, absence de tracking ou erreur GPU). Les anomalies et captures manquantes figurent dans les logs et le manifeste.

**Confidentialité :** cette commande publie les PNG et journaux sur GitHub ; inspecter la visibilité du dépôt avant utilisation.

Le fonctionnement complet n'est pas encore validé par compilation Windows/MSVC et exécution avec casque.

## Fidélité au laboratoire historique

Le laboratoire est monté à +10 m sur l'axe Y : les anciennes caméras (Y=2–6 visé) photographiaient **sous** le labo. Les caméras visent désormais la pièce à Y≈12, la face historique du terminal **(0,11.875,3.96)** et la zone lampe/ventilateur. La DLL World conserve les comportements d'origine, et le diagnostic n'invente pas de remplacement d'assets. Les logs `terminal.world_probe`, `world.ecosystem_probe` et `audio.world_probe` distinguent présence du code, publications et états réellement actifs. Ce changement est exclusivement un ajustement du canal d'observation, **pas** une correction démontrée des régressions visuelles ou sonores.
