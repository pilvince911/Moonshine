# Développement de Moonshine

La branche de référence `upstream/v2.0.1` conserve la base VibeShine 2.0.1. La branche `moonshine/windows-integration` ajoute un module C++, un moteur PowerShell embarqué et une interface Web. Le moteur reste installé par utilisateur sous le chemin OPi5 existant pour conserver ses fiches et UUID.

## Modules

| Emplacement | Rôle |
|---|---|
| `src/moonshine/` | Travaux en arrière-plan, processus dans la session Windows, canaux privés, confirmation et annulation |
| `src/confighttp_moonshine.cpp` | Authentification/CSRF, autorisations locales temporaires et adaptation à VibeShine |
| `tools/moonshine/` | Moteur 0.8.0 et reprise du synchroniseur 0.7.0 |
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
