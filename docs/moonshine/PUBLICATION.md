# Documentation et page publique de Moonshine

La documentation active et la page de présentation se trouvent dans `moonshine/main`. La version stable publiée est [Moonshine 1.0.1](https://github.com/pilvince911/Moonshine/releases/tag/v1.0.1).

## Afficher Moonshine à l’ouverture du dépôt

Dans le dépôt [pilvince911/Moonshine](https://github.com/pilvince911/Moonshine), ouvrir **Settings → General → Default branch**, cliquer sur le bouton de changement de branche, choisir **moonshine/main**, puis **Update** et confirmer. Cette branche contient le README de Moonshine. La branche historique `master` affiche encore la présentation VibeShine.

## Activer GitHub Pages

1. Ouvrir [Settings → Pages](https://github.com/pilvince911/Moonshine/settings/pages).
2. Sous **Build and deployment**, régler **Source** sur **Deploy from a branch**.
3. Sous **Branch**, choisir **moonshine/main**, puis le dossier **/docs**.
4. Cliquer sur **Save**.
5. Attendre que le déploiement **pages build and deployment** réussisse dans l’onglet **Actions**. La section Pages affichera ensuite le lien public.

Adresse prévue : **https://pilvince911.github.io/Moonshine/**.

Le dossier contient `index.html`, `moonshine-mark.svg` et `.nojekyll`. Il est prêt à être publié sans compilation du programme. Les réglages de Pages et de branche par défaut se font avec le compte propriétaire du dépôt.

## Le thème Moonshine

La page utilise son propre thème HTML/CSS : fond bleu nuit `#0d151c`, surfaces vertes `#14211e`, accent lime `#b8eb79` et logo officiel au croissant vert. `docs/index.html` contient la présentation et `docs/assets/moonshine.css` définit le thème, les formats téléphone et ordinateur, ainsi que les états de navigation au clavier.

Les polices système et les fichiers du dépôt suffisent au rendu. La page n’utilise ni police distante, ni script, ni thème Jekyll à télécharger. Le fichier `.nojekyll` garde cette publication statique; les options `theme:` et `remote_theme:` de Jekyll ne servent donc pas à personnaliser cette page. Les changements visuels se font dans la feuille de style et sont publiés avec `/docs`.

## Maintenir la documentation

| Fichier | Contenu |
|---|---|
| `README.md` | Présentation du dépôt, version stable, installation et liens utiles |
| `docs/index.html` | Page publique, téléchargement, installation, mise à jour et aide |
| `docs/assets/moonshine.css` | Thème Moonshine, mise en page adaptative et navigation au clavier |
| `docs/moonshine-mark.svg` | Logo public, identique au logo de l’application |
| `docs/moonshine/VALIDATION.md` | Commit distribué, empreinte et preuves des vérifications |
| `docs/moonshine/STANDALONE-1.0.md` | Fonctionnement de l’installation autonome |
| `tools/moonshine-setup/LIRE-MOI.txt` | Guide embarqué dans les prochains ZIP construits à partir de cette source |

Après une publication, vérifier que le bouton de téléchargement, les notes de version, l’empreinte et les références de code source correspondent au même ZIP. Vérifier les liens et les images avec le chemin `/Moonshine/`, ainsi que les ancres internes. Après l’activation, les changements dans `/docs` sur `moonshine/main` déclenchent une nouvelle publication du site.

Une correction de documentation n’exige pas de remplacer le ZIP. La balise `v1.0.1` conserve les sources exactes du paquet publié; la documentation courante peut être enrichie dans `moonshine/main`.

[README](../../README.md) · [Documentation GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)
