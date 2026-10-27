# Protocole embarqué 1

Le navigateur utilise la session HTTPS/CSRF existante de l'hôte. Les cinq routes Moonshine passent par les mêmes contrôles :

| Route | Méthode | Objet |
|---|---|---|
| `/api/moonshine/status` | GET | Disponibilité utilisateur, session, automatisation et dernier état |
| `/api/moonshine/jobs` | POST | Démarrer une action connue et une sélection connue |
| `/api/moonshine/jobs/{id}` | GET | Lire progression, aperçu et résultat |
| `/api/moonshine/jobs/{id}/confirm` | POST | Répondre à la confirmation active avec son nonce |
| `/api/moonshine/jobs/{id}/cancel` | POST | Demander une annulation coopérative |

Actions interactives : preview, sync, reset, restore, undo, profile, export, enable_auto, disable_auto. L'action auto est exclusivement interne. Sélections : all, ea, pilot, ea-pilot. Aucun chemin libre n'est accepté.

L'hôte crée un processus PowerShell non élevé dans la session active. Seuls ses handles stdin/stdout/stderr sont hérités; stderr non structuré est isolé. Un événement d'annulation est protégé par SID. Le premier message stdin contient le protocole, l'action, la sélection, l'identité utilisateur attendue, l'adresse loopback/pin et le jeton temporaire. Le worker rejette une identité différente et vérifie le package avant son travail.

Le jeton autorise uniquement GET/POST apps, DELETE des UUID privés OPi5 et GET session/status. Il ne permet pas de créer d'autres tokens, d'appeler les routes Moonshine ou de modifier la configuration globale. Il est révoqué après la fin du travail; le démarrage de l'hôte nettoie les jetons temporaires orphelins de ce namespace exact.

stdout émet des lignes JSON `type`/`data` : progress, log, snapshot, prompt, complete, error, cancelled. Les lignes et le journal sont bornés. Un prompt reçoit un nonce créé par l'hôte. Une réponse périmée, dupliquée, d'un autre travail ou avec le mauvais texte de reset est rejetée. Les confirmations ne sont pas enregistrées pour une utilisation future.

Annuler, fermer l'hôte ou changer d'utilisateur demande l'arrêt au prochain point sûr. Les mutations déjà envoyées sont vérifiées avant d'observer l'annulation. Les journaux du moteur prennent en charge les réponses perdues et interruptions. Une fin sans résultat confirmé reste un échec visible.
