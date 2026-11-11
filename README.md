<img src="src_assets/common/assets/web/public/images/moonshine-mark.svg" width="72" height="72" alt="Logo Moonshine">

# Moonshine

Hôte de streaming pour Windows avec une bibliothèque de jeux Xbox PC, Steam et EA. Lance tes jeux depuis un client **Moonlight**.

**Version 1.0.1 · ZIP autonome pour Windows 64 bits**

[Télécharger le ZIP](https://github.com/pilvince911/Moonshine/releases/download/v1.0.1/Moonshine-Windows-1.0.1.zip) · [Notes de version](https://github.com/pilvince911/Moonshine/releases/tag/v1.0.1) · [Empreinte SHA-256](https://github.com/pilvince911/Moonshine/releases/download/v1.0.1/Moonshine-Windows-1.0.1.sha256) · [GitHub Pages](https://pilvince911.github.io/Moonshine/)

## Nouveautés de la 1.0.1

- **Démarrage sans terminal.** Le raccourci et le démarrage de session passent par le lanceur graphique `Moonshine.exe`. La mise à jour reprend les anciennes entrées de démarrage reconnues de la 1.0.
- **Installation simplifiée.** La fenêtre propose l’installation ou la mise à jour selon l’état du PC. L’ancienne option de reprise du service 0.9 a été retirée.
- **Gestion quotidienne par l’icône.** Bibliothèque, démarrage, arrêt et entretien restent accessibles près de l’horloge.

## Avant de commencer

Le PC hôte doit utiliser Windows 64 bits; l’usage réel a été validé sur Windows 11. Il faut un client Moonlight, des jeux installés et les lanceurs Xbox PC, Steam ou EA correspondants. Le compte Windows qui utilise les jeux doit être connecté. Moonshine détecte les installations reconnues, pas l’ensemble des jeux offerts par un abonnement Game Pass.

## Installer sur Windows

1. Extrais le ZIP au complet dans un dossier local.
2. Ouvre **Moonshine.exe** depuis ton compte Windows habituel. Choisis **Installer Moonshine** et accepte la confirmation administrateur.
3. Suis la fenêtre pour préparer les pilotes signés si elle le demande. Redémarre Windows si l’étape l’indique.
4. Démarre Moonshine depuis l’icône près de l’horloge et ouvre la bibliothèque. Crée tes identifiants et appaire ton client Moonlight.

Le service et le gestionnaire s’installent dans `Program Files\Moonshine`. La bibliothèque appartient au compte Windows qui utilise les jeux. Ce compte doit être connecté pour les lancer. Les jeux utilisent leurs lanceurs installés. Le programme Moonshine est non signé et les pilotes fournis gardent leurs signatures originales.

[Guide Windows complet](tools/moonshine-setup/LIRE-MOI.txt)

## Mettre à jour une installation existante

Termine le stream et arrête le service Moonshine. Ferme sa fenêtre et quitte l’ancienne icône si elle est affichée. Extrais la 1.0.1 dans un nouveau dossier, ouvre **Moonshine.exe** et choisis **Mettre à jour Moonshine**. Le catalogue, l’appairage et les réglages sont conservés. Le gestionnaire réutilise les pilotes opérationnels.

## Utiliser Moonshine

- **Bibliothèque.** Analyse les installations Xbox PC, Steam et EA reconnues, vérifie l’aperçu des changements puis synchronise. Les actions de récupération permettent d’annuler les derniers changements ou de retirer les entrées gérées. Les jeux déjà configurés gardent leur identité.
- **Icône Windows.** Le lanceur graphique démarre le gestionnaire sans console. L’icône revient à la connexion du compte choisi. Son menu ouvre la bibliothèque, démarre ou arrête le service et donne accès à l’entretien. Quitter l’icône laisse le service dans son état actuel.
- **Entretien.** Réparation à partir du kit installé, sauvegarde privée, diagnostic et désinstallation avec archivage. Moonshine est aussi accessible dans **Applications installées**.
- **Connexion.** L’interface locale est à `https://localhost:48990/v2/library`. Le port de connexion du client Moonlight est **48989**. DLSS et Frame Generation se règlent dans les jeux.

## Dépannage

- **Icône introuvable :** regarde sous la flèche des icônes masquées de Windows ou ouvre **Moonshine** dans le menu Démarrer.
- **Jeu absent :** vérifie son installation et le compte Windows connecté, puis relance l’analyse de la bibliothèque. Vérifie le plan avant de confirmer la synchronisation.
- **Connexion Moonlight :** vérifie que le service est démarré et utilise le port **48989**. Le port **48990** sert à l’interface Web.
- **Installation endommagée :** arrête le service, puis utilise **Entretien → Réparer**. Le kit installé fournit les fichiers de référence. **Exporter un diagnostic** permet ensuite de préparer les journaux utiles à l’analyse.

## Sources et validation

La 1.0.1 intègre le lanceur graphique validé sur le PC du propriétaire et retire l’ancienne option de reprise du service 0.9. Les notes de version indiquent le commit exact du ZIP et les résultats de qualification logicielle. Le ZIP contient les sources et les licences.

[Installation autonome](docs/moonshine/STANDALONE-1.0.md) · [Validation](docs/moonshine/VALIDATION.md) · [Développement](docs/moonshine/DEVELOPMENT.md) · [Protocole de la bibliothèque](docs/moonshine/PROTOCOL.md) · [Publier la page GitHub](docs/moonshine/PUBLICATION.md)

Moonshine est un fork de [VibeShine](https://github.com/Nonary/vibeshine), issu de [Sunshine](https://github.com/LizardByte/Sunshine). La base VibeShine 2.0.1 est conservée dans `upstream/v2.0.1` et le développement Moonshine cible `moonshine/main`.

[GPL-3.0](LICENSE) · [Avis et attributions](NOTICE) · [Licences des pilotes](tools/moonshine-setup/LICENCES-PILOTES.txt)
