# Développement de Moonshine

La branche de référence `upstream/v2.0.1` conserve la base VibeShine 2.0.1. Les PR de la fork ciblent `moonshine/main`, afin de garder la référence amont intacte. La branche `moonshine/windows-integration` ajoute un module C++, un moteur PowerShell embarqué et une interface Web. Le moteur reste installé par utilisateur sous le chemin OPi5 existant pour conserver ses fiches et UUID.

## Modules

| Emplacement | Rôle |
|---|---|
| `src/moonshine/` | Travaux en arrière-plan, processus dans la session Windows, canaux privés, confirmation et annulation |
| `src/confighttp_moonshine.cpp` | Authentification/CSRF, autorisations locales temporaires et adaptation à VibeShine |
| `tools/moonshine/` | Moteur 0.8.1 et reprise du synchroniseur 0.7.0 |
| `src_assets/common/assets/web/views/MoonshineLibraryView.vue` | Bibliothèque et maintenance intégrées |
| `tests/moonshine/` | Politique native, vrai transport Windows et régressions du moteur |
| `tools/moonshine-dev/` | Contrôles de source et préparation de l'archive |

Les anciens modules de découverte restent dans l'historique amont et certains helpers partagés sont conservés pour le lancement/streaming. Ils ne sont plus exposés comme connecteurs de bibliothèque concurrents. Les fonctions partagées de lancement, de focus et de Frame Generation ne doivent pas être supprimées par recherche textuelle du mot Playnite.

## Contrôles locaux

Depuis la racine du dépôt :

```sh
python3 tools/moonshine-dev/validate_source.py
g++ -std=c++23 -Wall -Wextra -Werror -pedantic tests/moonshine/test_policy.cpp -o /tmp/moonshine-policy
/tmp/moonshine-policy
cd src_assets/common/assets/web
npm ci
npm run build
npm run test:unit
```

Sous Windows PowerShell 5.1 x64 :

```powershell
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\moonshine\Invoke-EngineTests.ps1
```

Le test utilise uniquement des données temporaires et des API simulées. Le test C++ Windows utilise de vrais processus/canaux et un script synthétique sans accès aux jeux. Voir le workflow `.github/workflows/moonshine.yml` pour sa compilation MSVC et la dépendance JSON épinglée.

## Build de l'hôte

Employer la chaîne de compilation et les dépendances Windows de VibeShine 2.0.1, puis construire la cible `sunshine`. Le build copie `tools/moonshine` à côté du binaire et l'installation ajoute le même répertoire. Le point d'entrée Web redirige vers l'interface v2.

Le nom interne de certains binaires/services amont reste utilisé par leur protocole. Un nom de projet ou un GUID MSI différent ne prouve pas que deux installations peuvent cohabiter. `MOONSHINE_BUILD_INSTALLER` reste OFF par défaut. Avant de l'activer pour distribution, qualifier le bootstrapper, les noms de service/répertoires, l'identité MSI, les pilotes, les mises à niveau et le retour à VibeShine. Aucun secret SignPath de Nonary ne doit être supposé disponible dans cette fork.

Les workflows amont de release/signature et tâches planifiées sont remplacés dans la branche de développement par les seuls contrôles Moonshine. Les mises à jour de code amont se font explicitement depuis la base épinglée.

## Données et reprise

Le protocole n'accepte pas de commande, script, chemin de travail ou mot de passe fourni par l'interface. Le worker provient du package de l'hôte et vérifie ses empreintes. La reprise d'OPi5 conserve les marqueurs historiques et ne crée pas de nouveaux UUID pour un jeu déjà géré.

Les commandes de synchronisation vérifient la session, l'identité du jeu et le catalogue avant chaque écriture. Les opérations ambiguës restent suspendues. Réutiliser la même commande de récupération; ne pas effacer `state.json`, `undo-control.json` ou `reset-control.json` pour forcer une application.

## Kit d’essai

### Service Windows

Le candidat 0.9.0 conserve le moteur 0.8.1. `tools/moonshine-service` prépare une copie de configuration et garde le même identifiant de synchronisation que l’essai portable sélectionné. Il ne migre pas le profil de production VibeShine. Le service est lié au SID du compte choisi; les travaux d’un autre utilisateur restent indisponibles. `service_constants.h` sépare MoonshineService et SunshineService; l’API de démarrage Windows ne doit jamais contrôler l’ancien hôte.

Les copies sont préparées dans un répertoire protégé temporaire, publiées après vérification, puis enregistrées auprès du SCM. Le reçu, les empreintes et le chemin absolu cité du wrapper bornent démarrage/arrêt/retrait. Les fichiers de configuration et Recovery sont privés; le code ne peut pas être remplacé par un utilisateur ordinaire. Une interruption de copie laisse le staging séparé. L’identité inconnue d’un service existant bloque l’opération.

Le wrapper ne transmet aucun handle hérité entre sessions. L’hôte ouvre ses propres diagnostics dans sa session et reçoit l’arrêt par événement nommé réservé à SYSTEM. Le canal du worker conserve son contrôle SID/PID. Le garde-fou d’affichage physique reste actif en cas d’échec de création virtuelle. Aucun écran physique n’est forcé sous une identité virtuelle absente.

`Invoke-ServiceSmoke.ps1` est limité à GitHub Actions et refuse tout service hôte préexistant. Il utilise le vrai SCM, le vrai wrapper, le vrai hôte HTTPS et le moteur embarqué. Le pilote, l’affichage exclusif, HDR et cadence réelle restent des essais matériels distincts. Les changements de service sur le PC du propriétaire se font uniquement quand il exécute le kit et accepte la confirmation Windows.

### Portable

`tools/moonshine-trial` contient le lanceur WPF et ses opérations réversibles. La fenêtre refuse l’élévation et une seconde fenêtre; l’hôte exige les marqueurs d’identité du kit. La copie privée est réparée uniquement à partir d’un paquet vérifié; les fichiers modifiés sont conservés dans Recovery. Le profil de l’hôte est adjacent au binaire privé et le moteur utilise le même identifiant d’essai pour ses données. L’index des essais utilise un verrou de fichier et des écritures atomiques.

`tests/moonshine/Invoke-TrialKitTests.ps1` construit la fenêtre WPF et vérifie sauvegarde, refus d’écrasement, corruption et réparation. `Invoke-HostSmoke.ps1` crée puis retire un compte standard temporaire sur la machine jetable de CI. Son enfant démarre le vrai binaire, vérifie HTTPS, autorisations, aperçu du moteur, révocation du jeton, absence d’écriture dans le profil de production et arrêt via un événement local protégé. Il ne simule ni une session de streaming ni un GPU.

Le workflow construit aussi `playnite-launcher`, `sunshine_wgc_capture`, `audio-info` et `dxgi-info`. Le helper de lancement reste une dépendance d’exécution partagée, même lorsque les importateurs de bibliothèque Steam et Playnite sont désactivés. Le stage inspecte les imports PE récursifs et exécute `--version` depuis le dossier du kit. Le cache de compilation ne remplace aucun contrôle.

Préréglage des nouvelles fiches : Moonshine propose « Frame Generation fournie par le jeu » et désactive Lossless Scaling dans les entrées créées. Ce choix est visible dans le plan avant confirmation. Diffusion permet de choisir un préréglage neutre ou sans FG. Les entrées déjà présentes et les profils explicites d’un jeu restent prioritaires; les fréquences, corrections de capture et réglages internes DLSS/FG ne sont pas imposés par ce préréglage.
