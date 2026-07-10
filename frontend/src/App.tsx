import { Navigate, Route, BrowserRouter as Router, Routes } from 'react-router-dom';
import { Nav } from './components/Nav';
import { SessionsProvider } from './context/SessionsContext';
import { NewSession } from './pages/NewSession';
import { Prompts } from './pages/Prompts';
import { SessionDetail } from './pages/SessionDetail';
import { SessionList } from './pages/SessionList';
import { Todos } from './pages/Todos';

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
          <Route path="/prompts" element={<Prompts />} />
        </Routes>
      </Router>
    </SessionsProvider>
  );
}
