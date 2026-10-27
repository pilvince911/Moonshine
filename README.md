# Moonshine

**Hôte de streaming Windows pour les clients Moonlight, avec la bibliothèque Xbox PC intégrée.**

Moonshine est une fork indépendante de [VibeShine](https://github.com/Nonary/vibeshine), lui-même issu de Sunshine. Nonary et les contributeurs amont restent les auteurs du moteur de streaming et de ses fonctionnalités. Le client garde son nom **Moonlight**; cette fork de l'hôte s'appelle **Moonshine**.

## Branche de développement

Le prototype part de **VibeShine 2.0.1**, commit `f078104b2b9224f080e503271dcea2a96fb573c1`, pour correspondre à la base utilisée par PL. La branche `upstream/v2.0.1` conserve cette référence; `moonshine/main` est la branche de destination propre à la fork et `moonshine/windows-integration` contient l'intégration proposée dans la PR nº 1. `master` suit encore la base reçue lors de la création de la fork.

**État : hôte Windows et kit d’essai autonome en validation. Aucun installateur Moonshine ni résultat de streaming sur le PC de PL n'est qualifié par cette branche.** Les vérifications de logiciel, le transport Windows, la compilation complète de l'hôte et les essais de jeu sont des étapes distinctes.

## Bibliothèque intégrée

- Le moteur PowerShell que nous avons développé est embarqué dans `tools/moonshine`, version 0.8.1 issue de la 0.7.0.
- Il retrouve les installations Xbox/GDK, Steam et EA prises en charge par notre découverte locale. Le périmètre initial est celui des jeux installés; il n'interroge pas tout le catalogue d'un abonnement Game Pass.
- La page Bibliothèque regroupe analyse, aperçu, confirmation, synchronisation, profils de diffusion et récupération.
- Les UUID, marqueurs, sauvegardes et données `%LOCALAPPDATA%\OPi5\VibeShine-Xbox` sont conservés pour reprendre nos anciennes entrées.
- Les importateurs Steam et Playnite amont sont désactivés, leurs routes de synchronisation et leurs commandes d'import sont retirées de l'interface. Steam Big Picture ne fait plus partie des applications par défaut. Les jeux Steam passent par notre moteur et utilisent toujours leur lanceur installé.
- Les applications personnelles, Desktop, Remote Input et Remote Monitor restent distinctes des jeux importés. Les anciennes entrées Steam/Playnite externes ne sont pas supprimées automatiquement et doivent être vérifiées si leur commande dépend de l'ancien connecteur.

## Fonctionnement Windows

L'hôte lance le moteur dans le compte Windows connecté, avec un jeton limité aux routes de bibliothèque nécessaires. Ce jeton transite dans un canal privé, n'est pas enregistré par le moteur, est révoqué à la fin et les autorisations temporaires abandonnées sont retirées au démarrage suivant.

Les opérations utilisent les mêmes sauvegardes, comparaisons de personnalisations, relectures API et journaux de reprise que le synchroniseur autonome. Les écritures attendent une session de streaming inactive. Annuler demande un arrêt à un point sûr; une écriture déjà envoyée doit être vérifiée. Le reset et le retour arrière mettent l'automatisation en pause.

Une tâche automatique OPi5 reconnue peut être transférée à l'automatisation intégrée; son XML est sauvegardé en privé. Une tâche personnalisée bloque la reprise plutôt que d'être remplacée. Le menu autonome reste un outil de secours manuel pendant la transition.

## Essai Windows séparé

Le workflow `.github/workflows/moonshine-host.yml` compile l’hôte complet, ses helpers et l’interface, vérifie les dépendances DLL, puis exige un démarrage réel sans droits administrateur et un aperçu produit par le moteur embarqué via HTTPS avant de publier son artefact d’essai. Consulter le résultat du commit exact : un script de test présent dans le dépôt ne prouve pas sa réussite.

Le kit propose une fenêtre Windows (`Demarrer-Moonshine.cmd`), une sauvegarde locale vérifiée et un arrêt propre. Il utilise son propre profil sous `%LOCALAPPDATA%\\OPi5\\Moonshine-Trial`, un catalogue neuf et le port Web 48990. Il ne reprend pas les tâches ni les données de production; arrêter temporairement l’autre hôte avant de démarrer cet essai. Voir [le parcours d’essai](tools/moonshine-trial/LIRE-MOI.txt).

Les versions portables sont des builds de développement non signés. Elles ne qualifient pas le streaming, les pilotes ou l’installateur. WebRTC et PyroWave sont désactivés dans ce kit. Le DLSS et la Frame Generation restent configurés dans les jeux.

## Validation et compilation

Voir [la procédure de développement](docs/moonshine/DEVELOPMENT.md), [les limites de validation](docs/moonshine/VALIDATION.md) et [le protocole du moteur](docs/moonshine/PROTOCOL.md). La CI dédiée exécute la politique native, le frontend, les régressions Windows PowerShell et le vrai pont Windows avec un moteur synthétique.

Le build standard du binaire reste celui de VibeShine, avec ses dépendances. Les cibles d'installateur sont désactivées par défaut; leur identité et leur comportement de mise à niveau doivent être qualifiés avant distribution. Les vérifications de mise à jour ciblent `pilvince911/Moonshine`.

## Licence et confidentialité

Le projet conserve la [GPL-3.0](LICENSE), les [avis amont](NOTICE) et les licences des dépendances. Aucun identifiant de PL, inventaire personnel, journal brut, jeton, clé de signature de production ou compte de service ne fait partie du dépôt. `tools/moonshine/Transport-Test.pfx` est exclusivement le certificat synthétique public des tests de transport; il ne doit jamais servir en production.

GitHub conserve les sources; les archives de développement et rapports de PL restent sur son Drive. Le dépôt ne publie pas de release ni d'installateur automatiquement.
