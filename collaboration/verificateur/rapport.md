# Vérification QA — matiere-pbd-001

- Cycle : `caca-aaa-001`
- Code examiné : `0942f59b4e91657ae47c021425270dab91207a90`
- Autorisation : `fac8846703a8b7ff380db78b57bb80215b621c6a`
- Tentative : 1
- Examen : inspection statique du diff de livraison (`f99ceb421de9bb48400913090a4627a25d8ddba3` → `0942f59b4e91657ae47c021425270dab91207a90`), implémentations associées et API/header PhysX/CUDA. Aucune exécution ni lecture de captures.
- **Résultat : `a_corriger` — destination `dev` — 2 constats.**

## QA-PBD-001 — Séchage superficiel non représenté

**Fichier :** `src/core/MatterPbdCuda.cu`, `Init` (ligne 22), `Environment` (lignes 47 à 58).

**Preuve :** les particules débutent toutes à `moisture=1`, puis chacune perd de l'humidité selon une formule locale fondée sur température, circulation d'air et vitesse. La livraison multiplie sensiblement le coefficient d'évaporation initial (`.00012` → `.008`), mais aucune détection de particule exposée, aucune diffusion ni conservation particulière de l'humidité dans le cœur n'existe. La phase humide/sèche est déterminée isolément par `w>.28`.

**Exigence :** la surface doit sécher et constituer une croûte mécaniquement plus rigide alors que l'intérieur reste humide, puis une fracture doit exposer cet intérieur.

**Conséquence :** le même mécanisme assèche également les particules internes. Le gradient surface/cœur indispensable à l'effet demandé n'est pas modélisé.

## QA-PBD-002 — Pas de vapeur issue de la matière transportée en CUDA

**Fichiers :** `src/core/MatterPbdCuda.cu` (lignes 24 à 59, 90 à 98), `src/core/PhysicsRuntime.cpp` (lignes 594 à 601), `src/core/PopulationCuda.cu` (lignes 129 à 150).

**Preuve :** `Environment` consomme les champs air/lumière et modifie uniquement les tableaux d'humidité, température et phase. `MatterEvolve` n'a ni sortie de flux de vapeur ni accumulation dans un champ spatialisé. La simulation des mouches ajoute un gradient calculé directement à partir de 48 échantillons de positions/humidité/température, ce qui ne constitue pas une émission de vapeur transportée par CUDA.

**Exigence :** la fracture de la croûte doit exposer de la matière humide et augmenter temporairement un flux de vapeur réellement transporté par les champs CUDA.

**Conséquence :** le système ne peut émettre, transporter ni renforcer ce flux au contact physique d'une fissure.

## Éléments statiquement présents

Le code comporte bien une instance `PxPBDParticleSystem` avec `PxParticleBuffer`, des profils de 262144 à 4194304 particules, des matériaux humide/sec et une lecture des particules par le noyau de simulation des mouches. Le prototype, la déclaration et l'appel `PopulationStep` ont été alignés. Cela ne constitue ni une preuve de compilation, ni une preuve de fréquence VR, de contacts physiques, de rendu ou d'absence de régression.

## Retour

Corriger les deux divergences dans le même billet. Aucune approbation architecturale n'est donnée. La vérification est statique uniquement ; aucune compilation ou exécution locale n'a été effectuée.
