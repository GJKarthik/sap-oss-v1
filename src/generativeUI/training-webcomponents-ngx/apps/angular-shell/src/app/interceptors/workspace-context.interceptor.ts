import { HttpInterceptorFn } from '@angular/common/http';

const WORKSPACE_STORAGE_KEY = 'training.workspace.v1';
const USER_ID_STORAGE_KEY = 'training.workspace.userId';

interface StoredWorkspaceIdentity {
  userId?: string;
  displayName?: string;
  teamName?: string;
}

function readStoredIdentity(): StoredWorkspaceIdentity {
  try {
    const raw = localStorage.getItem(WORKSPACE_STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as { identity?: StoredWorkspaceIdentity };
      return parsed.identity ?? {};
    }
  } catch {
    // Ignore corrupt local storage
  }

  return {
    userId: localStorage.getItem(USER_ID_STORAGE_KEY) ?? '',
    displayName: '',
    teamName: '',
  };
}

export const workspaceContextInterceptor: HttpInterceptorFn = (req, next) => {
  if (!(req.url.startsWith('/api') || req.url.startsWith('/v1'))) {
    return next(req);
  }

  const identity = readStoredIdentity();
  const setHeaders: Record<string, string> = {};

  if (identity.userId?.trim()) {
    setHeaders['X-Workspace-User'] = identity.userId.trim();
  }
  if (identity.displayName?.trim()) {
    setHeaders['X-Workspace-Display-Name'] = identity.displayName.trim();
  }
  if (identity.teamName?.trim()) {
    setHeaders['X-Workspace-Team-Name'] = identity.teamName.trim();
  }

  if (Object.keys(setHeaders).length === 0) {
    return next(req);
  }

  return next(req.clone({ setHeaders }));
};
