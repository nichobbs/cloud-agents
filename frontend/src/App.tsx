import { Navigate, Route, BrowserRouter as Router, Routes } from 'react-router-dom';
import { Nav } from './components/Nav';
import { SessionsProvider } from './context/SessionsContext';
import { Credentials } from './pages/Credentials';
import { Integrations } from './pages/Integrations';
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
    <SessionsProvider>
      <Router>
        <Nav />
        <Routes>
          <Route path="/" element={<Navigate to="/sessions" replace />} />
          <Route path="/sessions" element={<SessionList />} />
          <Route path="/sessions/new" element={<NewSession />} />
          <Route path="/sessions/:id" element={<SessionDetail />} />
          <Route path="/sessions/:id/todos" element={<Todos />} />
          <Route path="/repos" element={<Repos />} />
          <Route path="/prompts" element={<Prompts />} />
          <Route path="/profiles" element={<Profiles />} />
          <Route path="/credentials" element={<Credentials />} />
          <Route path="/integrations" element={<Integrations />} />
          <Route path="/webhooks" element={<Webhooks />} />
        </Routes>
      </Router>
    </SessionsProvider>
  );
}
