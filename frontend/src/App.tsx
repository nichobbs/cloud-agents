import { Navigate, Route, BrowserRouter as Router, Routes } from 'react-router-dom';
import { Nav } from './components/Nav';
import { RequireAuth } from './components/RequireAuth';
import { AuthConfigProvider } from './context/AuthConfigContext';
import { SessionsProvider } from './context/SessionsContext';
import { AuthCallback } from './pages/AuthCallback';
import { Credentials } from './pages/Credentials';
import { Integrations } from './pages/Integrations';
import { Library } from './pages/Library';
import { Login } from './pages/Login';
import { NewSession } from './pages/NewSession';
import { Profiles } from './pages/Profiles';
import { Prompts } from './pages/Prompts';
import { Repos } from './pages/Repos';
import { SessionDetail } from './pages/SessionDetail';
import { SessionList } from './pages/SessionList';
import { Todos } from './pages/Todos';
import { Webhooks } from './pages/Webhooks';

export function App() {
  return (
    <AuthConfigProvider>
      <SessionsProvider>
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
            <Route path="/repos" element={<RequireAuth><Repos /></RequireAuth>} />
            <Route path="/prompts" element={<RequireAuth><Prompts /></RequireAuth>} />
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
          </Routes>
        </Router>
      </SessionsProvider>
    </AuthConfigProvider>
  );
}
