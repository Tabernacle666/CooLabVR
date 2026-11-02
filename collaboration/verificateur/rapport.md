# Vérification QA — matiere-pbd-001 · caca-aaa-002 · tentative 1

- Code figé : `7be5552797c4531900f270078919e0e41c3a4846`
- Relais de livraison : `d71cc41375fbe659979e69239a2df0768a102e37`
- Base de comparaison : `e59e0346d2d4bd84c5a8636bff48b30ba7b47a24`
- Autorisation du programmeur : `120b90855db8c9b638751289e4748844718f20f1`
- Examen : inspection statique du diff source (9 fichiers), interfaces réelles PhysX épinglées par CMake, GPU CUDA/PBD, intégration HomePhysics, consommateurs shader, exigences du masterticket et rapport architectural. Aucun diagnostic/capture examiné.
- **Résultat : `a_corriger` — destination `dev` — 2 constats.**

## Éléments statiquement présents

- Configuration réelle PhysX PBD (`PxPBDParticleSystem`, `PxParticleBuffer`, `PxPBDMaterial`), phases et positions directement accessibles en CUDA. Les appels `createPBDParticleSystem`, `createPBDMaterial`, `createParticleBuffer`, `createPhase`, `setNbActiveParticles`, `raiseFlags` concordent avec les interfaces du tag PhysX `110.1-omni-and-physx-5.9.0`.
- Quatre profils de 262 144 à 4 194 304 particules, rendu par instances GPU aux positions PBD, champs CUDA d'humidité/température/vapeur, attraction des mouches et instrumentation GPU.
- Conservation statique de l'essentiel des corps, contraintes et services du laboratoire dans le diff.

## Constats imposant correction

### QA-MATIERE-001 — Croûte fissurable et interaction mécanique absentes

**Fichiers :** `src/core/PhysicsRuntime.cpp`, `src/core/MatterPbdCuda.cu`, `labs/labovr/HomePhysics.cpp`.

**Preuve :** `ConfigureMatter` crée une phase fluide humide et une phase sèche en auto-collision mais aucune liaison/structure de surface rompable. `Environment` calcule les contacts parmi six voisins fixés par les indices initiaux, puis change de phase selon l'humidité; aucun critère d'endommagement ni rupture de croûte par impact. `HomePhysics::Build` n'instancie pas de bâton pour le contact demandé.

**Exigence :** le masterticket impose qu'une croûte plus rigide se forme, se fissure au contact physique d'un bâton et révèle de l'humidité interne.

**Conséquence :** le séchage et la séparation de particules ne constituent pas une fracture mécanique démontrable de croûte. Ajouter le comportement physique réel sans animation de substitution.

### QA-MATIERE-002 — État de sécheresse non rendu visuellement

**Fichiers :** `src/core/MatterPbdCuda.cu`, `labs/labovr/HomePhysics.cpp`, `shaders/scene.hlsl`, `shaders/compute.hlsl`.

**Preuve :** `MatterPack` place `dry=1-moisture[i]` dans `GpuInstance.scale.w` mais fixe `material` à la valeur initiale. `HomePhysics::Build` assigne `Material::Bark` à toutes les particules. Les shaders MeshSolid ne consomment pas `scale.w` pour distinguer humide/sec ; ses usages dans les shaders d'atmosphère/optique sont réservés aux mouches/ombres.

**Exigence :** l'état de matière simulé doit produire une croûte de surface perceptible et vérifiable; ne pas confondre présence d'une valeur GPU et comportement rendu.

**Conséquence :** le cœur humide et la surface sèche ne sont pas distingués par le rendu ; le dessèchement demandé n'est pas vérifiable visuellement.

## Limites

Inspection statique uniquement. Aucune compilation, aucun lancement, aucun casque, aucune capture ni mesure de FPS effectués par QA. Les performances, contacts et effets visuels demandent les preuves locales ultérieures du propriétaire, seulement après QA conforme. Ne pas réveiller l'architecte : le billet est renvoyé au programmeur pour correction de ces deux constats.
