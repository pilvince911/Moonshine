# Installation autonome 1.0 : conditions de sortie

Le candidat service 0.9.0 a passé les essais logiciels du commit `96239aa250d10501f66a1eacca6a9496bc58d09a`. Son utilisation réelle a ensuite confirmé des lancements Xbox PC et EA, la création de l'écran virtuel exclusif et le retour à la topologie physique. Cette preuve couvre ce PC et ces essais; elle ne qualifie pas une installation neuve ni tous les jeux.

## Dépendances restantes

Le kit 0.9 copie le profil de l'essai 0.8.1 mais garde son identifiant et sa racine `OPi5\Moonshine-Trial\<id>\Sync`. Les commandes des jeux y visent `versions\0.8.1\Launch-Game.ps1`. Le kit ne fournit aucun pilote. La désinstallation de VibeShine peut retirer des périphériques ou composants partagés encore employés par Moonshine. Un avertissement de couche HDR Vulkan absente est aussi présent dans le diagnostic du kit service.

Les fichiers VHF de la base source déclarent le canal `msi-request-signing` : leur présence dans Git ne constitue pas un paquet de pilote distribuable. Ne pas livrer ces catalogues non signés comme si le travail de signature amont était déjà fait. Un paquet signé existant exige sa provenance, sa licence, ses empreintes, sa signature et sa compatibilité de protocole vérifiées. Ne pas générer de clé de production ni affaiblir les paramètres de sécurité Windows pour contourner un refus.

## Travail requis avant une distribution autonome

| Travail | Critère concret |
|---|---|
| Installation Windows propre | Installation sous l'identité Moonshine, sans index d'essais, profil OPi5 ni VibeShine préexistant; première connexion et appairage utilisables |
| Données et lancement | Racine propre à Moonshine; aucun chemin actif ne dépend d'un ancien dossier d'essai, de son extraction ou de VibeShine |
| Pilotes et HDR | Paquets vérifiés pour l'écran virtuel et les manettes; composants Vulkan requis présents; refus et redémarrage nécessaire clairement exposés |
| Migration facultative | Catalogue, UUID, appairages, images et personnalisations repris depuis une sauvegarde privée; seuls les chemins gérés sont réécrits; aucun import n'est nécessaire pour une installation neuve |
| Cycle de vie | Réparation hors ligne, mise à niveau de la même installation, désinstallation Windows et réinstallation vérifiées; aucune suppression de composant partagé sur simple recherche de nom |
| Démarrage et récupération | Service après redémarrage, compte utilisateur normal pour le moteur, reprise d'une installation interrompue et restauration de l'affichage après déconnexion/crash |
| Distribution | Archive/installeur, sources et licences concordants; empreintes; identité et statut de signature honnêtes; procédure de retour vérifiée |

La signature du programme Moonshine réduit les avertissements SmartScreen mais reste distincte de la signature exigée pour ses pilotes. Les outils de test et sources peuvent rester dans le dépôt; aucune version précédente ni exécution préalable de tests ne doit être requise sur le PC de l'utilisateur.

## Ménage livré séparément

`tools/moonshine-maintenance` fournit analyse, sauvegarde privée vérifiée et archivage des anciennes racines reconnues devenues inutilisées. Les services installés, leurs catalogues et les tâches empêchent le retrait des données encore nécessaires, même service arrêté. Les tâches reconnues ont un compte et une commande exacte; leurs XML sont sauvegardés avant retrait. Les profils inconnus, chemins personnalisés non résolus et jonctions sont conservés. Le script ne désinstalle ni hôte ni pilote.

La copie vérifiée précède tout archivage. Une relecture des dépendances, du contenu et des tâches limite les plans devenus périmés. Les changements sont journalisés dans un dossier privé. Une archive conserve les octets retirés sans suppression récursive. Les extractions arbitraires du Bureau et des Téléchargements demandent un choix explicite après la transition.

La séquence de validation finale est : sauvegarde, installation autonome neuve sur Windows jetable, migration sur le PC réel, désinstallation de l'ancien hôte avec remplacement vérifié des composants nécessaires, redémarrage Windows, essai Xbox/EA/Steam et restauration de l'affichage, puis archivage des anciens dossiers. Ne pas appeler la 0.9 « 1.0 autonome » pour éviter cette validation.
