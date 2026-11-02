# Vérification QA — matiere-pbd-001 (tentative 2)

- Cycle : `caca-aaa-001`
- Code examiné : `f8a95243cf1440ad9c11c67615d2def3bc553669`
- Relais figé : `bc5e1aef3f24840d27b131141149c7e5787ab19b`
- Autorisation : `fac8846703a8b7ff380db78b57bb80215b621c6a`
- Tentative : 2
- Examen : inspection statique du correctif de `0942f59b4e91657ae47c021425270dab91207a90` à `f8a95243cf1440ad9c11c67615d2def3bc553669`, de ses cinq fichiers source modifiés, des interfaces, appels PhysX/CUDA, dépendances de compilation et exigences du masterticket. Aucun lancement du jeu, aucune compilation et aucune lecture de captures.
- **Résultat : `conforme` — destination `arch` — 0 constat.**

## Retour des divergences de tentative 1

### QA-PBD-001 — Séchage superficiel, humidité interne

Corrigé statiquement dans `src/core/MatterPbdCuda.cu` : `Init` initialise l'exposition de la grille (lignes 23–25) ; `Environment` recalcule les six contacts de voisinage depuis les positions PhysX courantes (lignes 78–94), échange l'humidité entre voisins et applique une évaporation pondérée par l'exposition (lignes 95–106). Les particules non exposées ne subissent plus directement la même évaporation que la surface ; la phase sèche est distincte de la phase fluide. La conformité du comportement mécanique réel reste à confirmer par le diagnostic local.

### QA-PBD-002 — Émission et transport volumique de vapeur CUDA

Corrigé statiquement : `Environment` accumule les pertes d'eau dans `vapor.sources` (lignes 107–115), `TransportVapor` advecte le champ 3D avec `AirVelocity`, convection et diffusion (lignes 117–140), et `MatterEvolve` séquence ces noyaux ainsi que la mise à jour d'humidité sur le flux CUDA (lignes 171–185). `PhysicsRuntime.cpp` alloue et initialise le champ et ses buffers (lignes 968–981), le fait évoluer après les résultats PhysX et échange les buffers de densité (lignes 601–611), puis les libère à la destruction (lignes 288–294). `PopulationCuda.cu` échantillonne la densité et son gradient pour l'attraction des mouches (lignes 89–105, 168–181).

## Cohérence statique complémentaire

Les signatures et appels `MatterInitialize`, `MatterEvolve` et `PopulationStep` concordent entre headers, fichiers CUDA et `PhysicsRuntime.cpp`. `CMakeLists.txt` intègre les unités `.cu` concernées à la bibliothèque Core. Le code conserve l'accès aux positions des particules PhysX et le rendu des instances issues de ces positions. Aucun écart statique bloquant supplémentaire n'a été établi dans le périmètre examiné.

## Limites et suite du protocole

Cette vérification ne démontre ni compilation effective, ni absence de défaut à l'exécution, ni qualité physique/visuelle des fissures, de la vapeur ou des contacts, ni atteinte de 72 Hz. La conformité QA permet uniquement le diagnostic local par le propriétaire ; l'architecte ne juge l'acceptation qu'après des preuves complètes vérifiées sur le même SHA.

**Aucune divergence constatée.**
