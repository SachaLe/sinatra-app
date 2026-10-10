# 📸 Photos du mariage → Google Drive

Un petit site à partager avec vos invités (lien ou QR code). Ils ouvrent la page sur leur téléphone, choisissent leurs photos/vidéos, et les fichiers arrivent **directement dans un dossier de votre Google Drive**, préfixés par le prénom de l'invité (`Camille - IMG_1234.HEIC`).

- Pas de compte à créer pour les invités, pas d'appli à installer.
- Sélection multiple, barre de progression, reprise automatique en cas de coupure réseau.
- Les fichiers passent du téléphone **directement à Google Drive** (le serveur ne fait que délivrer une autorisation d'envoi) : pas de limite de taille côté hébergeur, les vidéos lourdes passent.
- Page `/qr` : QR code prêt à imprimer pour les tables.
- Page `/admin` (protégée par mot de passe) : état de la connexion, lien vers le dossier Drive, lien à partager.

## Comment ça marche

```
Téléphone invité ──(1) "je veux envoyer IMG_1234.jpg, 4 Mo"──▶ Ce serveur (Sinatra)
                                                                   │ (2) ouvre une session d'upload
                                                                   ▼     dans VOTRE Drive (OAuth)
Téléphone invité ◀──(3) URL d'upload à usage unique─────────────── Google Drive API
Téléphone invité ──(4) envoie le fichier directement──────────────▶ Google Drive
```

L'appli utilise le scope `drive.file` : elle ne peut voir **que** les fichiers qu'elle a créés elle-même, jamais le reste de votre Drive.

## Mise en place (≈ 15 min, une seule fois)

### 1. Créer les identifiants Google

1. Allez sur <https://console.cloud.google.com/>, créez un projet (ex. « Photos mariage »).
2. **API et services → Bibliothèque** → activez **Google Drive API**.
3. **API et services → Écran de consentement OAuth** (« Google Auth Platform ») :
   - Type d'utilisateur : **Externe**, nom de l'appli, votre e-mail.
   - Accès aux données / scopes : ajoutez `.../auth/drive.file`.
   - Audience : **Publiez l'application (« En production »)**. ⚠️ En mode « Test », Google fait expirer la connexion au bout de 7 jours. Le scope `drive.file` n'est pas sensible, donc aucune validation Google n'est nécessaire.
4. **Identifiants → Créer des identifiants → ID client OAuth** → type **Application Web**.
   - « URI de redirection autorisés » : `https://VOTRE-SITE/admin/oauth/callback` (vous l'aurez à l'étape 2 ; vous pourrez revenir l'ajouter).
5. Notez le **Client ID** et le **Client secret**.

### 2. Mettre le site en ligne (Render, gratuit)

1. Sur <https://render.com>, **New → Blueprint**, choisissez ce dépôt GitHub (le fichier `render.yaml` configure tout).
2. Renseignez les variables demandées :
   - `WEDDING_TITLE` : ex. `Léa & Hugo`
   - `ADMIN_PASSWORD` : un mot de passe pour la page `/admin`
   - `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` : de l'étape 1
   - `GOOGLE_REFRESH_TOKEN` : laissez vide pour l'instant
   - `ACCESS_CODE` : facultatif (voir plus bas)
3. Une fois déployé, vous avez une adresse du type `https://photos-mariage.onrender.com`. Ajoutez `https://photos-mariage.onrender.com/admin/oauth/callback` dans les URI de redirection Google (étape 1.4).

> Heroku fonctionne aussi (le `Procfile` est fourni) ; n'importe quel hébergeur Ruby fait l'affaire.

### 3. Connecter votre Google Drive

1. Ouvrez `https://VOTRE-SITE/admin` (identifiant : n'importe quoi, mot de passe : `ADMIN_PASSWORD`).
2. Cliquez **Connecter mon Google Drive**, choisissez votre compte Google, acceptez.
3. La page affiche un jeton : copiez-le dans la variable `GOOGLE_REFRESH_TOKEN` sur Render, et redéployez.
4. Retournez sur `/admin` : « Google Drive connecté ✔ ». Le dossier `Photos du mariage` est créé dans votre Drive.

### 4. Partager

- Le lien invité est affiché sur `/admin`.
- `/qr` donne un QR code à imprimer et poser sur les tables.
- **Testez avant le jour J** en envoyant une photo depuis votre propre téléphone.

## Options

| Variable | Rôle | Défaut |
|---|---|---|
| `WEDDING_TITLE` | Titre de la page | `Notre mariage` |
| `DRIVE_FOLDER_NAME` | Nom du dossier Drive | `Photos du mariage` |
| `ACCESS_CODE` | Si défini, seul le lien `/?code=…` permet d'envoyer (évite les envois d'inconnus) | — |
| `MAX_FILE_MB` | Taille max par fichier | `2048` |
| `ADMIN_PASSWORD` | Mot de passe de `/admin` | — (obligatoire) |
| `SESSION_SECRET` | Secret des cookies | généré |

## Bon à savoir

- Sur l'offre gratuite de Render, le site « s'endort » après 15 min sans visite : le premier chargement peut prendre ~30 s. Ouvrez la page vous-même juste avant la soirée, ou prenez l'offre payante pour le jour J.
- L'espace utilisé est celui de votre Google Drive (15 Go gratuits). Pour beaucoup de vidéos, prévoyez éventuellement Google One.

## Développement

```bash
bundle install
cp .env.example .env   # puis remplissez, et exportez les variables
bundle exec rackup -p 4567
bundle exec rspec
```
