# Qualification de Moonshine

Une vérification de source n'est pas un lancement de jeu. Cette branche distingue :

1. Politique native compilée et exécutée sur l'hôte de développement.
2. Contrôles de source, des dépendances du package et des empreintes.
3. Compilation du frontend complet.
4. Régressions réelles Windows PowerShell 5.1 avec données/API synthétiques.
5. Pont Windows compilé et exécuté avec vrais processus, canaux, nonce et annulation, sans jeux.
6. Compilation complète de l'hôte Windows, de ses helpers et du kit autonome; démarrage HTTPS sous un jeton sans droits administrateur et exécution réelle du worker embarqué.
7. Exécution dans le service Windows et le compte de PL; lancement réel des jeux; tests du streaming.
8. Installateur, mise à niveau, récupération et distribution.

Les contrôles 3 à 5 sont confiés au workflow d’intégration; le contrôle 6 dispose de son workflow Windows dédié. Consulter le résultat du commit exact; la présence d'un workflow ne signifie pas qu'il a démarré ou réussi. Les étapes 7 et 8 restent des qualifications distinctes même si tous les tests automatisés passent.

## Candidat de service 0.9.0

Le kit de service reprend une copie du profil portable 0.8.1 arrêté, avec ses certificats et UUID. Le moteur reste en version 0.8.1; l’hôte 0.9.0 utilise MoonshineService et réserve la synchronisation au compte sélectionné, sans droits administrateur effectifs.

Le workflow Windows doit vérifier le véritable service SCM : installation protégée, conservation du profil source et du catalogue, réparation d’un helper corrompu, enfant SYSTEM, worker utilisateur réel, révocation des jetons, arrêt, redémarrage et retrait. Ces essais sont limités à une machine jetable de CI. Le ZIP de service ne devient disponible qu’après réussite du scénario complet du commit livré. Une compilation réussie, un travail en attente ou une exécution annulée ne suffisent pas.

Sur le PC réel, il restera à essayer l’écran virtuel exclusif, les paramètres demandés par le client et la restauration après la sortie du jeu. Le kit réutilise les pilotes présents et n’en installe aucun. Garder VibeShine installé avec son service arrêté pendant cet essai : son désinstalleur prévoit aussi le retrait de composants d’écran et de manette encore réutilisés par Moonshine. Le retrait de l’ancien hôte doit être distingué du retrait de ces dépendances.

## Parcours sur le PC, lorsque le build de test sera prêt

- Sauvegarder la configuration actuelle et utiliser un build de test isolé avec un port distinct. Ne pas lancer deux services sur les mêmes ports.
- Vérifier que la bibliothèque correspond au compte connecté, que Desktop/Remote Input/Remote Monitor restent séparés des jeux et que les anciennes entrées OPi5 gardent leur identité.
- Analyser, lire le plan, synchroniser et répéter : aucun doublon ni mise à jour inutile au second passage.
- Personnaliser un titre/réglage, refaire l'analyse et vérifier sa conservation.
- Tester un jeu Steam, Xbox et EA, la fin du jeu et la fin du stream avec les réglages DLSS/FG applicables.
- Vérifier qu'une session active retient les écritures, puis qu'elles redeviennent disponibles après sa fermeture.
- Tester refus de confirmation, reset typé, annulation/reprise, restauration et expiration d'une ancienne confirmation.
- Vérifier la reprise de la tâche OPi5, son absence de concurrence avec l'automatisation intégrée, puis les pauses après reset/annulation.
- Créer le diagnostic depuis la page et joindre le retour réel. Les rapports privés restent sur Drive.

L'absence de Playnite n'est pas une preuve que les anciennes applications qui lançaient Playnite fonctionnent désormais seules. Ces entrées externes sont conservées et à reconfigurer si présentes. La synchronisation ne prend pas possession d'une application ambiguë par son seul titre.

Le kit isolé démarre avec un catalogue neuf et ignore les anciennes tâches. Il permet les premiers essais de lancement et de streaming en conservant le profil habituel. La reprise complète des anciennes fiches et tâches, le mode service Windows, les mises à niveau et l’installateur exigent ensuite un parcours de migration séparé. Ne pas confondre l’isolation de cet essai avec la qualification d’une migration en production.
