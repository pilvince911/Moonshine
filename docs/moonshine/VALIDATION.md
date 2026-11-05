# Validation de Moonshine 1.0.0

Le propriétaire a confirmé le bon fonctionnement de la RC2 sur son PC le 5 novembre 2026. La 1.0.0 est empaquetée à partir de cette base. Le commit, le résultat des essais et l’empreinte SHA-256 du ZIP distribué figurent dans les [notes de version](https://github.com/pilvince911/Moonshine/releases/tag/v1.0.0).

| Workflow | Vérifications |
|---|---|
| Moonshine integration | Synchroniseur et interface Web, lancement dans un compte standard, pont Windows, gestionnaire WPF et menu de l’icône. |
| Moonshine Windows host | Compilation complète, hôte HTTPS dans un compte normal, installation neuve, vrai service Windows et synchroniseur, réparation, mise à jour, sauvegarde, diagnostic et désinstallation. |
| Moonshine Windows prerequisites | Provenance, empreintes et signatures des fichiers originaux de pilotes fournis dans le ZIP. |

Le test de mise à jour utilise un reçu RC2 synthétique et une inscription Windows correspondante. Le test de migration 0.9 vérifie la reprise des données avant de relancer le synchroniseur depuis le programme installé. Ces essais emploient des profils temporaires sur des machines de CI.

Sur le PC, vérifie que les jeux et l’appairage sont encore présents après la mise à jour. Lance un jeu depuis Moonlight et vérifie la manette, la configuration d’affichage demandée par le client, la fin du stream et le retour de l’écran physique. La CI vérifie les pilotes par lecture de leur paquet. Le chargement des pilotes, l’affichage réel et le HDR se valident avec le matériel.

[Guide Windows](../../tools/moonshine-setup/LIRE-MOI.txt) · [Contrôles de développement](DEVELOPMENT.md)
