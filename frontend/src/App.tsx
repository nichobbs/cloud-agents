import { Navigate, Route, BrowserRouter as Router, Routes } from 'react-router-dom';
import { Nav } from './components/Nav';
import { RequireAuth } from './components/RequireAuth';
import { AuthConfigProvider } from './context/AuthConfigContext';
import { OrgProvider, useOrgs } from './context/OrgContext';
import { SessionsProvider } from './context/SessionsContext';
import { AuthCallback } from './pages/AuthCallback';
import { Credentials } from './pages/Credentials';
import { Inbox } from './pages/Inbox';
import { Integrations } from './pages/Integrations';
import { AcceptInvitation } from './pages/AcceptInvitation';
import { Library } from './pages/Library';
import { Login } from './pages/Login';
import { NewSession } from './pages/NewSession';
import { Profiles } from './pages/Profiles';
import { Organisations } from './pages/Organisations';
import { Prompts } from './pages/Prompts';
import { Repos } from './pages/Repos';
import { Search } from './pages/Search';
import { SessionDetail } from './pages/SessionDetail';
import { SessionList } from './pages/SessionList';
import { Todos } from './pages/Todos';
import { Webhooks } from './pages/Webhooks';

/// Every page loads its data on mount, so switching organisation remounts the
/// whole routed tree (sessions poller included) by keying it on the active
/// org id: no page needs its own refetch-on-switch logic.
function OrgScoped({ children }: { children: React.ReactNode }) {
  const { activeOrgId, personalId } = useOrgs();
  // Personal maps to one stable key so the org list loading in does not remount.
  const key = activeOrgId === personalId ? 'personal' : activeOrgId;
  return <SessionsProvider key={key}>{children}</SessionsProvider>;
}

export function App() {
  return (
    <AuthConfigProvider>
      <OrgProvider>
      <OrgScoped>
        <Router>
          <Nav />
          <Routes>
            <Route path="/" element={<Navigate to="/sessions" replace />} />
            <Route path="/login" element={<Login />} />
            <Route path="/auth/callback" element={<AuthCallback />} />
            <Route
              path="/sessions"
              element={<RequireAuth><SessionList /></RequireAuth>}
            />
            <Route
              path="/sessions/new"
              element={<RequireAuth><NewSession /></RequireAuth>}
            />
            <Route
              path="/sessions/:id"
              element={<RequireAuth><SessionDetail /></RequireAuth>}
            />
            <Route
              path="/sessions/:id/todos"
              element={<RequireAuth><Todos /></RequireAuth>}
            />
            <Route path="/inbox" element={<RequireAuth><Inbox /></RequireAuth>} />
            <Route path="/repos" element={<RequireAuth><Repos /></RequireAuth>} />
            <Route path="/prompts" element={<RequireAuth><Prompts /></RequireAuth>} />
            <Route path="/search" element={<RequireAuth><Search /></RequireAuth>} />
            <Route path="/profiles" element={<RequireAuth><Profiles /></RequireAuth>} />
            <Route path="/library" element={<RequireAuth><Library /></RequireAuth>} />
            <Route
              path="/credentials"
              element={<RequireAuth><Credentials /></RequireAuth>}
            />
            <Route
              path="/integrations"
              element={<RequireAuth><Integrations /></RequireAuth>}
            />
            <Route path="/webhooks" element={<RequireAuth><Webhooks /></RequireAuth>} />
            <Route path="/orgs" element={<RequireAuth><Organisations /></RequireAuth>} />
            <Route path="/invite/:token" element={<RequireAuth><AcceptInvitation /></RequireAuth>} />
          </Routes>
        </Router>
      </OrgScoped>
      </OrgProvider>
    </AuthConfigProvider>
  );
}
