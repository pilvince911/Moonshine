import { expect, test, type Page } from '@playwright/test';

async function library(page: Page, idle = true, isolated = false) {
  const id = 'a'.repeat(32), nonce = 'b'.repeat(32);
  const calls: { action?: string; nonce?: string; accept?: boolean; text?: string; csrf?: string }[] = [];
  let job: Record<string, unknown> | null = null;
  await page.route('**/api/**', async (route) => {
    const request = route.request(), path = new URL(request.url()).pathname;
    if (!path.startsWith('/api/')) { await route.continue();return; }
    let body: unknown = { status: true };
    if (path === '/api/auth/status') body = { authenticated: true, credentials_configured: true, login_required: false };
    else if (path === '/api/configLocale') body = { locale: 'en' };
    else if (path === '/api/csrf-token') body = { csrf_token: 'synthetic-ui-csrf' };
    else if (path === '/api/metadata') body = { platform: 'windows', version: '0.8.0', encoder_status: { state: 'ready', h264: true } };
    else if (path === '/api/session/status') body = { status: true, activeSessions: idle ? 0 : 1, appRunning: !idle };
    else if (path === '/api/apps' && request.method() === 'GET') body = { apps: [
      { uuid: 'desktop', name: 'Desktop', cmd: '' },
      { uuid: '706c6f73-7862-8830-81ec-2118ff82baaa', name: 'Jeu Steam existant', 'plos-xbox-owner': 'plos-xbox-sync/1', 'plos-xbox-key': 'steam:990080' },
    ] };
    else if (path === '/api/moonshine/status') body = { available: true, automatic: false, session_idle: idle, brand: 'Moonshine', isolated, engine_version: '0.8.1', job, snapshot: null };
    else if (path === '/api/moonshine/jobs' && request.method() === 'POST') {
      const input = request.postDataJSON();calls.push({ action: input.action, csrf: request.headers()['x-csrf-token'] });
      const reset = input.action === 'reset';
      job = { job_id: id, action: input.action, state: 'awaiting_confirmation', percent: -1, message: 'Plan synthétique à confirmer', logs: [],
        prompt: { nonce, message: 'Vérifier le plan synthétique', expected: reset ? 'REINITIALISER' : 'APPLIQUER', typed: reset, rows: [{ title: 'Jeu Steam existant', action: reset ? 'remove' : 'update', reason: 'Modification synthétique' }] } };
      body = job;
    } else if (path === `/api/moonshine/jobs/${id}/confirm`) {
      calls.push({ ...request.postDataJSON(), csrf: request.headers()['x-csrf-token'] });
      job = { ...job, state: 'completed', message: 'Terminé', prompt: null };body = job;
    } else if (path === `/api/moonshine/jobs/${id}`) body = job;
    else if (path === '/api/apps' && request.method() !== 'GET') throw new Error('The library must use the native job controller.');
    await route.fulfill({ json: body });
  });
  await page.goto('/v2/library');
  await expect(page.getByRole('heading', { name: 'Vos jeux, directement.' })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Analyser', exact: true })).toBeEnabled();
  return calls;
}

test('existing historical entries appear without a write and filters do not change sync scope', async ({ page }) => {
  const calls = await library(page);
  await expect(page.getByRole('heading', { name: 'Jeu Steam existant' })).toBeVisible();
  await page.getByLabel('Plateforme', { exact: true }).selectOption('ea');
  await expect(page.getByText('Aucun jeu ne correspond aux filtres.')).toBeVisible();
  expect(calls).toEqual([]);
  await page.getByRole('button', { name: 'Effacer les filtres' }).click();
  await expect(page.getByRole('heading', { name: 'Jeu Steam existant' })).toBeVisible();
});

test('declining the actual plan sends its nonce and CSRF token', async ({ page }) => {
  const calls = await library(page);
  await page.getByRole('button', { name: 'Synchroniser', exact: true }).click();
  await expect(page.getByRole('heading', { name: 'Confirmer le plan' })).toBeVisible();
  await page.getByRole('button', { name: 'Revenir', exact: true }).click();
  expect(calls).toEqual([
    { action: 'sync', csrf: 'synthetic-ui-csrf' },
    { nonce: 'b'.repeat(32), accept: false, text: '', csrf: 'synthetic-ui-csrf' },
  ]);
});

test('reset requires the exact typed confirmation before sending acceptance', async ({ page }) => {
  const calls = await library(page);
  await page.getByText('Maintenance et récupération', { exact: true }).click();
  await page.getByRole('button', { name: 'Remettre les entrées à zéro' }).click();
  const confirm = page.getByRole('button', { name: 'Confirmer le retrait' });
  await expect(confirm).toBeDisabled();
  await page.getByLabel('Saisir REINITIALISER').fill('reinitialiser');await expect(confirm).toBeDisabled();
  await page.getByLabel('Saisir REINITIALISER').fill('REINITIALISER');await confirm.click();
  expect(calls[1]).toEqual({ nonce: 'b'.repeat(32), accept: true, text: 'REINITIALISER', csrf: 'synthetic-ui-csrf' });
});

test('an active stream retains mutation controls while allowing an analysis', async ({ page }) => {
  const calls = await library(page, false);
  await expect(page.getByRole('button', { name: 'Synchroniser', exact: true })).toBeDisabled();
  await expect(page.getByRole('button', { name: 'Analyser', exact: true })).toBeEnabled();
  await expect(page.getByText('Une session ou une application de streaming est active.', { exact: false })).toBeVisible();
  expect(calls).toEqual([]);
});

test('trial context and Moonshine branding are visible', async ({ page }) => {
  await library(page, true, true);
  await expect(page.getByText('Mode essai ·', { exact: false })).toBeVisible();
  const mark = page.locator('img[src$="moonshine-mark.svg"]').first();
  await expect(mark).toBeVisible();
  await expect.poll(() => mark.evaluate((image: HTMLImageElement) => image.complete && image.naturalWidth > 0)).toBe(true);
  await page.screenshot({ path: 'test-results/moonshine-library-trial.png', fullPage: true });
});
