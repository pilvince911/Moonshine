# Installation autonome 1.0 : conditions de sortie

La RC1 autonome a passé ses contrôles logiciels au commit `ef0335dd886d8a8218aa408c123149f1ccb72e8c`. Le propriétaire a ensuite signalé son installation fonctionnelle après retrait de VibeShine et préparation des pilotes du ZIP. La RC2 conserve ce parcours et ajoute la finition Windows; sa validation réelle précède la release 1.0.

## Critères de la RC2

| Parcours | Critère |
|---|---|
| Installation neuve | Aucun ancien kit, profil ou test préalable requis; pilotes signés fournis et préparation explicite |
| Mise à jour RC1 | Même bibliothèque, appairage, UUID et réglages; programme précédent conservé |
| Icône | Compte normal, lancement caché à la connexion, une instance, actions de bibliothèque et service |
| Entretien | Réparation vérifiée, sauvegarde privée, diagnostic limité sans identifiants ni certificats |
| Retrait Windows | Inscription propre, archivage du programme, bibliothèque et pilotes partagés conservés |
| Matériel | Xbox/EA/Steam, manette, écran exclusif/HDR, fin du stream, restauration et redémarrage |
| Distribution finale | ZIP, guide, sources/licences et empreinte concordants; release GitHub après validation |

## Limites et preuve

Les tests Windows couvrent un vrai service SCM et un vrai worker normal, mais pas les pilotes chargés ni l'affichage d'un GPU de runner. Le test de mise à niveau utilise un reçu antérieur synthétique; la mise à jour de la RC1 réelle est à essayer. L'icône utilise le compte interactif, et les opérations de service gardent la confirmation administrateur quand Windows la demande.

Les 19 fichiers originaux des pilotes proviennent de l'asset VibeShine 2.0.1 épinglé. Signatures, catalogues, protocole, licences et provenance restent contrôlés. Aucune clé de production n'est générée et aucune politique Windows n'est abaissée. Le programme Moonshine reste non signé; WebRTC/PyroWave, TrueHDR et l'optimisation interne DLSS/FG ne font pas partie de cette qualification.

Le ménage 0.2 archive les essais reconnus et peut retirer le seul ancien service 0.9 après sauvegarde. Il protège l'installation autonome et ses données. Les archives sont à conserver jusqu'à validation; aucune purge générale n'est nécessaire pour utiliser Moonshine.
