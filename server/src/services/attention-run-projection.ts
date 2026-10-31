// Share only in-flight internal timestamp projections, never actor-specific feed
// data or completed reads. Routes/services construct attentionService(db) separately.
export interface AttentionRunProjectionRow {
  agentId: string;
  runKey: string | null;
  createdAt: Date;
}

type Projection = AttentionRunProjectionRow[];
type CompanyState = {
  tail: Promise<unknown>;
  pending: Map<string, Promise<Projection>>;
};

export function createAttentionRunProjectionMemo() {
  const databases = new WeakMap<object, Map<string, CompanyState>>();
  return (db: object, companyId: string, key: string, load: () => PromiseLike<Projection>): Promise<Projection> => {
    let companies = databases.get(db);
    if (!companies) {
      companies = new Map();
      databases.set(db, companies);
    }
    let state = companies.get(companyId);
    if (!state) {
      state = { tail: Promise.resolve(), pending: new Map() };
      companies.set(companyId, state);
    }
    const pending = state.pending.get(key);
    if (pending) return pending;
    // Different key sets also serialize per company; a facet burst cannot launch
    // multiple JSONB scans. Failures must not poison later work or be cached.
    const result = state.tail.then(() => load());
    state.tail = result.catch(() => undefined);
    state.pending.set(key, result);
    const settled = () => {
      state.pending.delete(key);
      if (state.pending.size === 0) companies.delete(companyId);
    };
    void result.then(settled, settled);
    return result;
  };
}

export const memoAttentionRunProjection = createAttentionRunProjectionMemo();
