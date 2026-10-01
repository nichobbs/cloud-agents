import { createContext, useCallback, useContext, useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { AUTH_CHANGED_EVENT, isSignedIn } from '../lib/auth';
import { getStoredOrgId, ORG_CHANGED_EVENT, storeOrgId } from '../lib/activeOrg';
import { orgsApi } from '../lib/orgs';
import type { Org } from '../lib/orgs';

interface OrgValue {
  orgs: Org[];
  /** The personal organisation id ('' until the list has loaded). */
  personalId: string;
  /** Selected organisation id; the personal id when none is selected. */
  activeOrgId: string;
  activeOrg: Org | undefined;
  /** Select an organisation; the personal id (or '') selects personal. */
  setActiveOrg: (id: string) => void;
  reload: () => Promise<void>;
}

const OrgContext = createContext<OrgValue>({
  orgs: [],
  personalId: '',
  activeOrgId: '',
  activeOrg: undefined,
  setActiveOrg: () => undefined,
  reload: async () => undefined,
});

export function useOrgs(): OrgValue {
  return useContext(OrgContext);
}

/// Loads GET /api/orgs once signed in and tracks the active organisation.
/// The selection itself lives in localStorage (lib/activeOrg) because
/// apiFetch must read it for every request.
export function OrgProvider({ children }: { children: ReactNode }) {
  const [orgs, setOrgs] = useState<Org[]>([]);
  const [personalId, setPersonalId] = useState('');
  const [stored, setStored] = useState(getStoredOrgId);

  const reload = useCallback(async () => {
    if (!isSignedIn()) {
      setOrgs([]);
      setPersonalId('');
      return;
    }
    try {
      const list = await orgsApi.list();
      setOrgs(list.orgs);
      setPersonalId(list.personal);
      const current = getStoredOrgId();
      if (current && !list.orgs.some(o => o.id === current && !o.suspended)) storeOrgId('');
    } catch {
      /* older backend or transient failure: stay on the current organisation */
    }
  }, []);

  useEffect(() => {
    void reload();
    const onAuth = () => { void reload(); };
    const onOrg = () => setStored(getStoredOrgId());
    window.addEventListener(AUTH_CHANGED_EVENT, onAuth);
    window.addEventListener(ORG_CHANGED_EVENT, onOrg);
    return () => {
      window.removeEventListener(AUTH_CHANGED_EVENT, onAuth);
      window.removeEventListener(ORG_CHANGED_EVENT, onOrg);
    };
  }, [reload]);

  const setActiveOrg = useCallback(
    (id: string) => storeOrgId(id === personalId ? '' : id),
    [personalId],
  );

  const activeOrgId = stored || personalId;
  const activeOrg = orgs.find(o => o.id === activeOrgId);

  return (
    <OrgContext.Provider value={{ orgs, personalId, activeOrgId, activeOrg, setActiveOrg, reload }}>
      {children}
    </OrgContext.Provider>
  );
}
