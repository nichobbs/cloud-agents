const ORG_KEY = 'cloud_agents_org';

/** Fired when the stored organisation changes, so OrgContext follows a
 *  fallback made deep inside apiFetch. */
export const ORG_CHANGED_EVENT = 'cloud-agents-org-changed';

/** The selected non-personal organisation id; '' means the personal one. */
export function getStoredOrgId(): string {
  try {
    return localStorage.getItem(ORG_KEY) ?? '';
  } catch {
    return '';
  }
}

export function storeOrgId(id: string): void {
  try {
    if (id) localStorage.setItem(ORG_KEY, id);
    else localStorage.removeItem(ORG_KEY);
  } catch {
    /* storage unavailable: the selection just won't survive a reload */
  }
  window.dispatchEvent(new Event(ORG_CHANGED_EVENT));
}
