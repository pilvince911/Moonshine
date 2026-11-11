# Validation de Moonshine 1.0.1

Le propriétaire a confirmé le lancement sans console avec la candidate 1.0.1 le 11 novembre 2026. La version finale reprend ce lanceur et retire l’option de reprise du service 0.9 de l’interface. Le commit, le résultat des essais et l’empreinte SHA-256 du ZIP distribué figurent dans les [notes de version](https://github.com/pilvince911/Moonshine/releases/tag/v1.0.1).

## Paquet distribué

| Référence | Valeur |
|---|---|
| Version stable | `v1.0.1`, publiée le 11 novembre 2026 |
| Commit des sources du ZIP | [`a257c52030d06766259fa76ff9dd113e9991888d`](https://github.com/pilvince911/Moonshine/commit/a257c52030d06766259fa76ff9dd113e9991888d) |
| Archive | `Moonshine-Windows-1.0.1.zip`, 86 480 199 octets |
| SHA-256 | `c6e33b03c9018124a2c346cf8d92b6400d7c79ddf46491def0adb193a7a83114` |
| Vérification après téléchargement | 382 fichiers du manifeste et 2 290 fichiers de sources embarquées vérifiés |

[Télécharger le ZIP](https://github.com/pilvince911/Moonshine/releases/download/v1.0.1/Moonshine-Windows-1.0.1.zip) · [Télécharger l’empreinte](https://github.com/pilvince911/Moonshine/releases/download/v1.0.1/Moonshine-Windows-1.0.1.sha256)

## Qualification logicielle

Les trois exécutions suivantes ont réussi sur le commit exact du ZIP.

| Workflow | Résultats et vérifications |
|---|---|
| [Moonshine integration](https://github.com/pilvince911/Moonshine/actions/runs/43042242973) | 459 autotests du synchroniseur, 23 contrôles du gestionnaire, interface Web, pont Windows et vrais lancements du raccourci et de l’icône dans un compte standard. |
| [Moonshine Windows host](https://github.com/pilvince911/Moonshine/actions/runs/43042242959) | 201 contrôles de l’hôte et 48 du vrai service Windows : installation neuve, synchroniseur, réparation, mise à jour, sauvegarde, diagnostic et désinstallation. |
| [Moonshine Windows prerequisites](https://github.com/pilvince911/Moonshine/actions/runs/43042243159) | Provenance, empreintes et signatures des 19 fichiers originaux de pilotes fournis dans le ZIP. |

Le test de mise à jour utilise un reçu 1.0 synthétique, son ancienne entrée de démarrage PowerShell et son raccourci CMD. Le test dans un compte standard vérifie les deux entrées du lanceur graphique et l’absence de console attachée au gestionnaire. Le test de migration 0.9 vérifie la reprise des données avant de relancer le synchroniseur depuis le programme installé. Ces essais emploient des profils temporaires sur des machines de CI.

Sur le PC, vérifie que les jeux et l’appairage sont encore présents après la mise à jour. Lance un jeu depuis Moonlight et vérifie la manette, la configuration d’affichage demandée par le client, la fin du stream et le retour de l’écran physique. La CI vérifie les pilotes par lecture de leur paquet. Le chargement des pilotes, l’affichage réel et le HDR se valident avec le matériel.

[Guide Windows](../../tools/moonshine-setup/LIRE-MOI.txt) · [Contrôles de développement](DEVELOPMENT.md)
