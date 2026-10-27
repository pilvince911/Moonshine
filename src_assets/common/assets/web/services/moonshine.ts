import { apiGet, apiPost } from '@/api/client';
export type SyncAction = 'preview' | 'sync' | 'reset' | 'restore' | 'undo' | 'profile' | 'export' | 'enable_auto' | 'disable_auto';
export type SyncScope = 'all' | 'ea' | 'pilot' | 'ea-pilot';
export interface SyncGame { uuid: string; key: string; title: string; platform: string; action: string; reason: string; changed_fields: string[]; managed: boolean; profile: string; }
export interface SyncSnapshot { schema: string; created: string; inventory_created?: string; version: string; tests: number; cached: boolean; games: SyncGame[]; scope: SyncScope; reset?: { status: string; automatic_hold?: boolean } | null; rollback?: { status: string } | null; }
export interface SyncPrompt { nonce: string; message: string; expected: string; typed: boolean; rows: { title: string; action: string; reason: string }[]; }
export interface SyncJob { job_id: string; action: string; state: string; message: string; percent: number; snapshot?: SyncSnapshot | null; prompt?: SyncPrompt | null; logs: string[]; }
export interface SyncStatus { isolated?: boolean; available: boolean; automatic: boolean; session_idle: boolean; brand: string; engine_version: string; job: SyncJob | null; snapshot: SyncSnapshot | null; }
export const terminal = (state: string) => ['completed', 'failed', 'cancelled'].includes(state);
export const getSyncStatus = () => apiGet<SyncStatus>('/api/moonshine/status');
export const getSyncJob = (id: string) => apiGet<SyncJob>(`/api/moonshine/jobs/${encodeURIComponent(id)}`);
export const startSyncJob = (action: SyncAction, scope: SyncScope, extra: Record<string, string> = {}) => apiPost<SyncJob>('/api/moonshine/jobs', { action, scope, ...extra });
export const confirmSyncJob = (id: string, nonce: string, accept: boolean, text = '') => apiPost<SyncJob>(`/api/moonshine/jobs/${encodeURIComponent(id)}/confirm`, { nonce, accept, text });
export const cancelSyncJob = (id: string) => apiPost<SyncJob>(`/api/moonshine/jobs/${encodeURIComponent(id)}/cancel`, {});
export function matchesGame(game: SyncGame, query: string, platform: string, state: string): boolean {
  const text = `${game.title} ${game.key} ${game.platform}`.toLocaleLowerCase();
  return (!query.trim() || text.includes(query.trim().toLocaleLowerCase())) && (!platform || game.platform === platform) &&
    (!state || (state === 'changes' && ['add', 'update'].includes(game.action)) || (state === 'issues' && ['conflict', 'pending', 'unknown'].includes(game.action)) || (state === 'ready' && ['existing', 'unchanged'].includes(game.action)));
}
