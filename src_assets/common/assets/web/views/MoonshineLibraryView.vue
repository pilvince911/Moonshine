<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';
import { ApiError } from '@/api/client';
import { appCoverUrl, appName, appUuid, fetchApps, type AppRecord } from '@/services/apps';
import { cancelSyncJob, confirmSyncJob, getSyncJob, getSyncStatus, matchesGame, startSyncJob, terminal, type SyncAction, type SyncGame, type SyncJob, type SyncScope, type SyncSnapshot, type SyncStatus } from '@/services/moonshine';

const coverFailures = ref(new Set<string>());
const status = ref<SyncStatus | null>(null), job = ref<SyncJob | null>(null), snapshot = ref<SyncSnapshot | null>(null);
const apps = ref<AppRecord[]>([]), loading = ref(true), error = ref(''), query = ref(''), platform = ref(''), state = ref('');
const creationMode = ref('game-provided'), creationDirty = ref(false);
const creationLabels: Record<string, string> = { 'game-provided': 'Frame Generation fournie par le jeu', off: 'Aucune coordination FG', unmanaged: 'Réglages neutres', invalid: 'À réparer dans Diffusion' };
const scope = ref<SyncScope>('all'), confirmationText = ref(''), submitting = ref(false), profileGame = ref(''), profileMode = ref('game-provided');
let timer: number | undefined, refreshing = false, disposed = false, generation = 0;
const busy = computed(() => submitting.value || (!!job.value && !terminal(job.value.state)));
const recovery = computed(() => {
  const data = snapshot.value;
  if (data?.rollback?.status === 'invalid' || data?.reset?.status === 'invalid') return 'Journal de récupération à vérifier. Créez le diagnostic avant toute synchronisation.';
  if (data?.rollback?.status === 'undoing') return 'Annulation interrompue : utilisez Reprendre l’annulation dans Maintenance.';
  if (data?.reset && ['resetting', 'restoring'].includes(data.reset.status)) return 'Remise à zéro interrompue : terminer le retrait ou reprendre la restauration.';
  if (data?.reset?.automatic_hold) return 'Remise à zéro terminée. Réimportez les jeux ou restaurez la sauvegarde; automatisation en pause.';
  return '';
});
const blocked = computed(() => !!snapshot.value?.rollback && ['undoing', 'invalid'].includes(snapshot.value.rollback.status) || !!snapshot.value?.reset && ['resetting', 'restoring', 'invalid'].includes(snapshot.value.reset.status));
const writable = computed(() => status.value?.available && status.value.session_idle && !busy.value);
function owned(app: AppRecord): boolean { return typeof (app['opi5-xbox-key'] ?? app['plos-xbox-key']) === 'string' && ['opi5-xbox-sync/1', 'plos-xbox-sync/1'].includes(String(app['opi5-xbox-owner'] ?? app['plos-xbox-owner'])); }
const allGames = computed<SyncGame[]>(() => {
  const scanned = (snapshot.value?.games ?? []).map((game) => ({ ...game }));
  const byKey = new Map(scanned.map((game) => [game.key, game]));
  for (const app of apps.value.filter(owned)) {
    const key = String(app['opi5-xbox-key'] ?? app['plos-xbox-key']), existing = byKey.get(key);
    if (existing) {
      // Pending discovery can still refer to an entry already in the host.
      if (!existing.uuid) { existing.uuid = appUuid(app);existing.managed = true; }
      continue;
    }
    const historical: SyncGame = {
      uuid: appUuid(app), key, title: appName(app), platform: key.split(':')[0] ?? '', action: 'unknown',
      reason: snapshot.value
        ? 'Entrée conservée dans l’hôte; installation non retrouvée dans cette analyse. Aucune suppression automatique.'
        : 'Entrée existante; analyser les installations pour vérifier son état.',
      changed_fields: [], managed: true, profile: 'unmanaged',
    };
    scanned.push(historical);byKey.set(key, historical);
  }
  return scanned;
});
const games = computed(() => allGames.value.filter((game) => matchesGame(game, query.value, platform.value, state.value)));
const otherApps = computed(() => apps.value.filter((app) => !owned(app)));
const changes = computed(() => allGames.value.filter((game) => ['add', 'update'].includes(game.action)).length);
const issues = computed(() => allGames.value.filter((game) => ['conflict', 'pending'].includes(game.action)).length);
const managed = computed(() => allGames.value.filter((game) => game.managed));
const labels: Record<string, string> = { add: 'À ajouter', update: 'À mettre à jour', unchanged: 'À jour', existing: 'Déjà présent', conflict: 'À vérifier', pending: 'En attente', unknown: 'À analyser' };
const prompt = computed(() => job.value?.prompt ?? null);
function cover(game: SyncGame): string { const app = apps.value.find((item) => appUuid(item) === game.uuid);const url = app ? appCoverUrl(app) : '';return coverFailures.value.has(url) ? '' : url; }
function coverFailed(game: SyncGame): void { const url = cover(game);if (url) coverFailures.value.add(url); }
function adopt(next: SyncJob): void { if (next.action === 'creation_profile' && terminal(next.state) && next.snapshot?.creation_profile) { creationMode.value = next.snapshot.creation_profile;creationDirty.value = false; }const previousNonce = job.value?.prompt?.nonce;job.value = next;if (next.snapshot) snapshot.value = next.snapshot;if (next.prompt?.nonce !== previousNonce) confirmationText.value = ''; }
function message(cause: unknown): string { if (cause instanceof ApiError && cause.payload && typeof cause.payload === 'object' && typeof (cause.payload as {error?: unknown}).error === 'string') return (cause.payload as {error: string}).error;return cause instanceof Error ? cause.message : 'La demande a échoué. Réessayez ou créez le diagnostic.'; }
async function refresh(): Promise<void> {
  if (refreshing || disposed) return;refreshing = true;const current = generation;
  try {
    const next = await getSyncStatus();if (disposed || current !== generation) return;status.value = next;
    if (!creationDirty.value && next.creation_profile && next.creation_profile !== 'invalid') creationMode.value = next.creation_profile;
    if (next.job) adopt(next.job);else if (next.snapshot) snapshot.value = next.snapshot;
    const nextApps = await fetchApps();if (!disposed && current === generation) apps.value = nextApps;
  } catch (cause) { if (!disposed) error.value = message(cause); }
  finally { refreshing = false;loading.value = false; }
}
async function run(action: SyncAction, extra: Record<string, string> = {}): Promise<void> {
  if (busy.value) return;submitting.value = true;error.value = '';generation++;
  try { adopt(await startSyncJob(action, scope.value, extra)); }
  catch (cause) { error.value = message(cause); }
  finally { submitting.value = false; }
}
async function answer(accept: boolean): Promise<void> {
  if (!job.value || !prompt.value || submitting.value) return;
  const id = job.value.job_id, nonce = prompt.value.nonce;submitting.value = true;error.value = '';generation++;
  try { adopt(await confirmSyncJob(id, nonce, accept, confirmationText.value)); }
  catch (cause) { error.value = message(cause); }
  finally { submitting.value = false; }
}
async function cancel(): Promise<void> {
  if (!job.value || submitting.value) return;submitting.value = true;generation++;
  try { adopt(await cancelSyncJob(job.value.job_id)); } catch (cause) { error.value = message(cause); }
  finally { submitting.value = false; }
}
async function poll(): Promise<void> {
  if (disposed || refreshing || document.hidden) return;
  if (job.value && !terminal(job.value.state)) {
    refreshing = true;const current = generation, id = job.value.job_id;
    try { const previous = job.value.state, next = await getSyncJob(id);if (disposed || current !== generation || id !== job.value?.job_id) return;adopt(next);if (terminal(next.state) && previous !== next.state) { refreshing = false;await refresh(); } }
    catch (cause) { error.value = message(cause); }
    finally { refreshing = false; }
  } else await refresh();
}
onMounted(() => { void refresh();timer = window.setInterval(() => void poll(), 1500); });
onBeforeUnmount(() => { disposed = true;generation++;if (timer) window.clearInterval(timer); });
</script>

<template>
  <section class="moonshine-library" aria-labelledby="moonshine-title">
    <header class="ms-heading"><div><p class="ms-eyebrow">BIBLIOTHÈQUE WINDOWS · MOONSHINE</p><h1 id="moonshine-title">Vos jeux, directement.</h1><p>Xbox PC, Steam et EA réunis par notre moteur de synchronisation.</p></div><RouterLink to="/library/new" class="ms-link">Application manuelle ↗</RouterLink></header>
    <p v-if="status?.isolated" class="ms-notice" role="status">{{ status.execution_mode === 'service' ? 'Essai en service Windows · synchronisation dans votre session utilisateur; catalogue repris de votre essai portable.' : 'Mode essai · catalogue et données de synchronisation séparés de votre installation actuelle.' }}</p>
    <p v-if="error" role="alert" class="ms-notice ms-error">{{ error }}</p>
    <p v-if="recovery" role="status" class="ms-notice">{{ recovery }}</p>
    <p v-if="status && !status.available" class="ms-notice">Ouvrez la session Windows qui contient vos jeux. Le moteur lit la bibliothèque de ce compte.</p>
    <p v-else-if="status && !status.session_idle" class="ms-notice">Une session ou une application de streaming est active. Les écritures attendent sa fermeture.</p>
    <p v-if="snapshot?.cached" class="ms-muted">Dernière analyse conservée. Analyser relit les installations et le catalogue actuel.</p>
    <div class="ms-stats"><div><small>JEUX RÉPERTORIÉS</small><strong>{{ allGames.length }}</strong></div><div><small>CHANGEMENTS PROPOSÉS</small><strong>{{ changes }}</strong></div><div><small>À VÉRIFIER / EN ATTENTE</small><strong>{{ issues }}</strong></div></div>
    <div class="ms-toolbar"><label class="ms-search"><span class="ms-sr">Rechercher un jeu</span><input v-model="query" type="search" placeholder="Titre ou identifiant du jeu…" /></label><select v-model="platform" aria-label="Plateforme"><option value="">Toutes les plateformes</option><option value="steam">Steam</option><option value="xbox">Xbox</option><option value="ea">EA</option></select><select v-model="state" aria-label="État"><option value="">Tous les états</option><option value="changes">Changements</option><option value="issues">À vérifier</option><option value="ready">À jour / présents</option></select><button type="button" @click="query = ''; platform = ''; state = ''">Effacer les filtres</button></div>
    <div class="ms-actions"><label>Sélection à synchroniser <select v-model="scope" :disabled="busy"><option value="all">Tous les jeux</option><option value="ea">EA seulement</option><option value="pilot">Pilote Steam + Xbox</option><option value="ea-pilot">Pilote EA</option></select></label><div><button type="button" :disabled="busy || !status?.available" @click="run('preview')">Analyser</button><button type="button" class="ms-primary" :disabled="!writable || blocked" @click="run('sync')">Synchroniser</button></div></div>
    <p class="ms-muted">Nouvelles fiches : {{ creationLabels[status?.creation_profile || 'game-provided'] }}. Préréglage visible dans le plan; les fiches existantes conservent leurs choix.</p>
    <p class="ms-muted">{{ games.length }} / {{ allGames.length }} jeu(x) affiché(s). Les filtres d’affichage ne limitent pas la synchronisation.</p>
    <div v-if="job" class="ms-operation" role="status" aria-live="polite"><div><strong>{{ job.message }}</strong><button v-if="busy && !submitting" type="button" @click="cancel">Annuler à un point sûr</button></div><progress v-if="busy" :value="job.percent >= 0 ? job.percent : undefined" max="100" /></div>
    <section v-if="prompt" class="ms-confirm" aria-labelledby="ms-confirm-title"><h2 id="ms-confirm-title">Confirmer le plan</h2><p>{{ prompt.message }}</p><p>Une sauvegarde précède les écritures. Les jeux installés et les entrées personnelles sont protégés.</p><ul><li v-for="(row, index) in prompt.rows" :key="index"><strong>{{ row.title }}</strong> · {{ row.action }}<small>{{ row.reason }}</small></li></ul><label v-if="prompt.typed">Saisir {{ prompt.expected }}<input v-model="confirmationText" autocomplete="off" spellcheck="false" /></label><div class="ms-confirm-actions"><button type="button" :disabled="submitting" @click="answer(false)">Revenir</button><button type="button" class="ms-primary" :disabled="submitting || prompt.typed && confirmationText !== prompt.expected" @click="answer(true)">{{ prompt.typed ? 'Confirmer le retrait' : 'Appliquer' }}</button></div></section>
    <div class="ms-games"><article v-for="game in games" :key="game.key" class="ms-game"><div class="ms-cover"><img v-if="cover(game)" :src="cover(game)" alt="" loading="lazy" @error="coverFailed(game)" /><span v-else aria-hidden="true">☾</span></div><div class="ms-game-info"><small>{{ game.platform.toUpperCase() }}</small><h2>{{ game.title }}</h2><p>{{ game.reason || 'Pochette et lancement vérifiés à la prochaine analyse.' }}</p><details v-if="game.changed_fields.length"><summary>Réglages concernés</summary><code>{{ game.changed_fields.join(', ') }}</code></details><RouterLink v-if="game.managed" :to="`/library/${encodeURIComponent(game.uuid)}`">Tous les réglages de l’entrée ↗</RouterLink></div><span class="ms-pill" :data-state="game.action">{{ labels[game.action] || game.action }}</span></article></div>
    <p v-if="!loading && !games.length" class="ms-empty">{{ allGames.length ? 'Aucun jeu ne correspond aux filtres.' : 'Cliquez sur Analyser pour retrouver vos installations.' }}</p>
    <details class="ms-panel"><summary>Diffusion · DLSS et Frame Generation</summary><p><strong>Préréglage des nouvelles fiches</strong></p><div class="ms-toolbar"><select v-model="creationMode" aria-label="Préréglage des nouvelles fiches" :disabled="busy" @change="creationDirty = true"><option value="game-provided">Frame Generation fournie par le jeu</option><option value="off">Aucune coordination FG</option><option value="unmanaged">Réglages neutres</option></select><button type="button" :disabled="!writable" @click="run('creation_profile', { mode: creationMode })">Enregistrer pour les nouvelles fiches</button></div><p class="ms-muted">DLSS/FG restent activés dans le jeu. Le préréglage désactive Lossless Scaling pour les nouvelles entrées, sans imposer de fréquence, de pilote ou de correction de capture. Pour un jeu sans FG, choisir Aucune coordination FG.</p><p><strong>Profil d’une fiche déjà synchronisée</strong></p><p>Choisissez un profil par jeu. Les options graphiques internes se règlent dans le jeu.</p><div class="ms-toolbar"><select v-model="profileGame" aria-label="Jeu à configurer"><option value="">Sélectionner une entrée gérée</option><option v-for="game in managed" :key="game.uuid" :value="game.uuid">{{ game.title }}</option></select><select v-model="profileMode" aria-label="Profil de diffusion"><option value="game-provided">Frame Generation fourni par le jeu</option><option value="off">Aucune coordination FG</option><option value="unmanaged">Conserver les réglages sans les gérer</option></select><button type="button" :disabled="!writable || blocked || !managed.some((game) => game.uuid === profileGame)" @click="run('profile', { game_id: profileGame, mode: profileMode })">Enregistrer le profil</button></div><p class="ms-muted">Synchroniser appliquera le choix après aperçu et confirmation. Le contrôle de santé VibeShine et le client restent nécessaires pour valider la diffusion réelle.</p><RouterLink to="/settings">Réglages de diffusion de l’hôte ↗</RouterLink></details>
    <details class="ms-panel"><summary>Maintenance et récupération</summary><p>Automatisation : <strong>{{ status?.automatic ? 'Activée · session et toutes les 10 minutes' : 'Désactivée' }}</strong></p><div class="ms-maintenance"><button type="button" :disabled="!writable || blocked || status?.automatic" @click="run('enable_auto')">Activer l’automatisation</button><button type="button" :disabled="busy || !status?.available || !status?.automatic" @click="run('disable_auto')">Désactiver</button><button type="button" :disabled="!writable || snapshot?.rollback?.status === 'undoing'" @click="run('reset')">Remettre les entrées à zéro</button><button type="button" :disabled="!writable || !snapshot?.reset || snapshot.reset.status === 'restored'" @click="run('restore')">Restaurer le reset</button><button type="button" :disabled="!writable" @click="run('undo')">{{ snapshot?.rollback?.status === 'undoing' ? 'Reprendre l’annulation' : 'Annuler la dernière synchronisation' }}</button><button type="button" :disabled="busy || !status?.available" @click="run('export')">Créer le diagnostic sur le Bureau</button></div><p class="ms-muted">Le reset et l’annulation mettent l’automatisation en pause. Les applications personnelles et les jeux installés restent en place.</p></details>
    <details class="ms-panel"><summary>Autres applications de l’hôte · {{ otherApps.length }}</summary><p>Ces entrées restent gérées individuellement et ne sont pas importées comme des jeux.</p><ul class="ms-host-apps"><li v-for="app in otherApps" :key="appUuid(app)"><RouterLink :to="`/library/${encodeURIComponent(appUuid(app))}`">{{ appName(app) || appUuid(app) }} ↗</RouterLink></li></ul></details>
    <details v-if="job?.logs.length" class="ms-panel"><summary>Journal de l’opération</summary><pre>{{ job.logs.join('\n') }}</pre></details>
    <footer class="ms-muted"><span v-if="snapshot">Moteur {{ snapshot.version }} · {{ snapshot.tests }} autotests à l’ouverture de cette opération · Analyse : {{ snapshot.inventory_created || 'à refaire' }}</span><span v-else>Moteur embarqué {{ status?.engine_version || '…' }} · connexion locale gérée par l’hôte.</span></footer>
  </section>
</template>

<style scoped>
.moonshine-library{color:#e9eef6;background:#101720;border:1px solid #2b3948;border-radius:20px;padding:clamp(18px,3vw,34px);max-width:1280px;margin:auto;color-scheme:dark}.ms-heading{display:flex;justify-content:space-between;gap:24px;align-items:start}.moonshine-library h1,.moonshine-library h2{color:#e9eef6}.ms-heading .ms-eyebrow{color:#b8eb79}.ms-heading h1{font-size:clamp(28px,4vw,40px);letter-spacing:-.04em;margin:8px 0}.ms-eyebrow{font-size:10px;letter-spacing:.16em;color:#b8eb79;font-weight:700}.ms-heading p,.ms-muted{color:#a0b0c3;font-size:13px;line-height:1.65}.ms-link,a{color:#b8eb79;text-decoration:none}a:hover{text-decoration:underline}.ms-stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px;margin:28px 0 22px}.ms-stats>div{padding:18px;background:#19232e;border:1px solid #2e3d4b;border-radius:12px}.ms-stats small{font-size:10px;letter-spacing:.06em;color:#a5b5c7}.ms-stats strong{display:block;font-size:32px;color:#b8eb79;margin-top:5px}.ms-toolbar,.ms-actions,.ms-maintenance{display:flex;gap:10px;flex-wrap:wrap;align-items:center}.ms-toolbar{margin:12px 0}.ms-search{flex:1;min-width:180px}.ms-search input{width:100%}input,select,button{border:1px solid #3c4e61;border-radius:8px;background:#1b2735;color:#edf2f8;padding:10px 13px;font:inherit;font-size:13px}button{cursor:pointer;font-weight:600}button:disabled{opacity:.42;cursor:default}button:not(:disabled):hover{border-color:#b8eb79}.ms-primary{background:#b8eb79;color:#152114;border-color:#b8eb79}input:focus-visible,select:focus-visible,button:focus-visible,a:focus-visible,summary:focus-visible{outline:2px solid #b8eb79;outline-offset:3px}.ms-actions{justify-content:space-between;margin:20px 0 12px}.ms-actions label{display:flex;gap:10px;align-items:center;font-size:12px;color:#aebed0}.ms-actions>div{display:flex;gap:10px}.ms-games{display:grid;gap:11px;margin:16px 0 24px}.ms-game{display:flex;gap:18px;align-items:center;border:1px solid #2d3b4a;background:#18222e;border-radius:12px;padding:14px}.ms-cover{flex:none;width:64px;height:94px;background:#263646;border-radius:7px;overflow:hidden;display:grid;place-items:center;color:#b8eb79;font-size:35px}.ms-cover img{width:100%;height:100%;object-fit:cover}.ms-game-info{flex:1;min-width:0}.ms-game-info small{color:#b6a4e9;font-size:10px;font-weight:700}.ms-game-info h2{font-size:17px;margin:4px 0 7px}.ms-game-info p{font-size:12px;line-height:1.5;color:#a3b4c8;margin:0 0 6px}.ms-game-info a{font-size:11px}.ms-pill{flex:none;padding:6px 10px;border-radius:20px;background:#2b3b4b;font-size:11px;color:#c3d3e5}.ms-pill[data-state=conflict],.ms-pill[data-state=pending]{color:#edc58b}.ms-pill[data-state=add],.ms-pill[data-state=update]{color:#b8eb79}.ms-notice{background:#333320;border:1px solid #6c6438;padding:13px;border-radius:8px;font-size:13px}.ms-error{background:#402b30;border-color:#8c535d;color:#f4c9cb}.ms-operation{padding:16px;background:#203238;border-radius:10px}.ms-operation>div{display:flex;justify-content:space-between;align-items:center;gap:16px}.ms-operation strong{font-size:13px}.ms-operation progress{width:100%;height:4px;margin-top:14px;accent-color:#b8eb79}.ms-confirm{background:#24382f;border:1px solid #91bb69;border-radius:12px;padding:22px;margin-top:18px}.ms-confirm h2{margin:0 0 10px;font-size:21px}.ms-confirm p{font-size:13px;line-height:1.6}.ms-confirm ul{max-height:260px;overflow:auto;padding-left:20px}.ms-confirm li{margin:12px 0;font-size:13px}.ms-confirm li small{display:block;color:#b8cdbd;margin-top:4px}.ms-confirm label{display:grid;gap:8px}.ms-confirm-actions{display:flex;justify-content:end;gap:12px;margin-top:18px}.ms-panel{padding:18px 0;border-top:1px solid #304051}.ms-panel summary{font-weight:600;cursor:pointer}.ms-panel p{font-size:13px;color:#afbed0;line-height:1.65}.ms-panel pre{max-height:240px;overflow:auto;white-space:pre-wrap;font-size:11px;background:#0d141d;padding:15px;border-radius:8px}.ms-host-apps{display:flex;gap:12px 22px;flex-wrap:wrap;list-style:none;padding:0;font-size:13px}.ms-empty{text-align:center;padding:40px;color:#adbed2}.ms-sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}details code{display:block;overflow-wrap:anywhere;font-size:11px;margin:9px 0}footer{margin-top:15px}@media(max-width:640px){.ms-heading{display:block}.ms-stats{gap:7px}.ms-stats>div{padding:12px}.ms-stats strong{font-size:25px}.ms-game{gap:12px;flex-wrap:wrap}.ms-game-info{min-width:180px}.ms-pill{margin-left:76px}.ms-actions label{flex-wrap:wrap}.ms-operation>div{align-items:start;flex-direction:column}.ms-toolbar select{max-width:100%}}
</style>
