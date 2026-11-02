# Vérification QA — matiere-pbd-001 (tentative 3)

- Cycle : `caca-aaa-001`
- Code livré et vérifié : `7a16b64087624530b666b8e7df1120be66e88f51`
- Relais figé : `c718f99f97ebb269cd6bcf081dcf5eee2ecc6feb`
- Base de la tentative : `f8a95243cf1440ad9c11c67615d2def3bc553669`
- Autorisation : `fac8846703a8b7ff380db78b57bb80215b621c6a`
- Examen : inspection statique complète du diff livré (un fichier, deux lignes corrigées), des appels et définitions PhysX concernés, de la configuration CMake, des interfaces PhysX/CUDA du projet et des exigences du masterticket.
- **Résultat : `conforme` — destination `arch` — 0 constat.**

## Examen du correctif

1. **`PxPBDParticleSystem::createPhase`** — Dans `src/core/PhysicsRuntime.cpp`, l'expression de phase humide construit désormais explicitement `PxParticlePhaseFlags(PxParticlePhaseFlag::eParticlePhaseFluid)` avant l'opérateur `|` avec `eParticlePhaseSelfCollide`. L'interface épinglée `PxPBDParticleSystem.h` attend `PxParticlePhaseFlags` et `foundation/PxFlags.h` définit `PxFlags::operator|(enumtype)` : la forme livrée est statiquement compatible. La phase sèche conserve un seul drapeau, convertible en `PxParticlePhaseFlags`.

2. **`PxPhysics::createParticleBuffer`** — L'appel est corrigé de trois arguments (`count,0,cuda`) à deux (`count,cuda`). `CMakeLists.txt` épingle précisément `NVIDIA-Omniverse/PhysX` au tag `110.1-omni-and-physx-5.9.0` ; son `physx/include/PxPhysics.h` déclare `createParticleBuffer(PxU32 maxParticles, PxCudaContextManager* cudaContextManager)`. Le nouvel appel correspond à cette signature, sans paramètre `maxVolumes`.

3. **Intégration conservée** — Les appels `MatterInitialize` et `MatterEvolve` dans `PhysicsRuntime.cpp` concordent avec `MatterPbdCuda.h` et `MatterPbdCuda.cu` ; `CMakeLists.txt` inclut les unités CUDA dans `Core`. Les phases, positions, vitesses et indicateurs de mise à jour continuent d'employer le véritable tampon particulaire PhysX. Le diff livré ne modifie pas les calculs d'humidité, de transport de vapeur, de rendu ou les interactions du laboratoire déjà examinés lors de la tentative précédente.

## Limites et protocole

La présente inspection n'a exécuté ni compilation, ni jeu, ni diagnostic local et n'a consulté aucune capture. Elle ne prouve ni les performances à 72 Hz, ni les phénomènes physiques, ni l'absence de régression visible. La conformité QA autorise seulement le diagnostic local du propriétaire sur le SHA livré ; l'architecte décide ensuite, à partir des preuves, de l'acceptation ou du recul.

**Aucune divergence constatée.**
