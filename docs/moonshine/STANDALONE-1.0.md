# Installation autonome de Moonshine 1.0.1

La version 1.0.1 est distribuée en ZIP pour Windows 64 bits. Elle utilise le lanceur graphique validé avec la candidate 1.0.1. Elle crée un profil neuf à partir du ZIP ou met à jour un profil Moonshine existant.

| Parcours | Comportement |
|---|---|
| Installation neuve | Le gestionnaire installe MoonshineService et crée une bibliothèque pour le compte choisi. La préparation des pilotes signés est une étape distincte. |
| Mise à jour d’une installation | Le gestionnaire conserve le catalogue, les UUID, l’appairage et les réglages. Les fichiers du programme précédent restent dans une copie de secours. |
| Connexion Windows | L’icône démarre dans le compte choisi. Son menu ouvre la bibliothèque et gère le service. |
| Entretien | Le kit installé permet la réparation, la sauvegarde privée et l’export d’un diagnostic limité. |
| Désinstallation | Moonshine archive le programme après sauvegarde. La bibliothèque et les pilotes partagés sont conservés. |

Le service protège ses fichiers dans `Program Files\Moonshine`. Les jeux et le synchroniseur s’exécutent dans le compte Windows interactif. Les opérations système demandent la confirmation Windows lorsque nécessaire.

Les pilotes inclus proviennent du paquet VibeShine 2.0.1 épinglé et gardent leurs signatures d’origine. Le programme Moonshine est non signé. L’essai du service dans GitHub Actions couvre le service Windows, la conservation du profil et le synchroniseur. L’affichage, les manettes physiques et le HDR se vérifient sur le PC hôte.

[Guide d’installation](../../tools/moonshine-setup/LIRE-MOI.txt) · [ZIP et notes de version](https://github.com/pilvince911/Moonshine/releases/tag/v1.0.1)
