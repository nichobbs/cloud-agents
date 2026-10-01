import { useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { useOrgs } from '../context/OrgContext';
import { orgsApi } from '../lib/orgs';

/// Landing page of an invitation link. Accepts once on mount, then switches
/// to the new organisation.
export function AcceptInvitation() {
  const { token = '' } = useParams();
  const navigate = useNavigate();
  const { reload, setActiveOrg } = useOrgs();
  const [error, setError] = useState('');
  const started = useRef(false);

  useEffect(() => {
    // Single-use token: guard against StrictMode's double effect run.
    if (started.current) return;
    started.current = true;
    orgsApi
      .acceptInvitation(token)
      .then(async org => {
        await reload();
        // Navigate before switching: the switch remounts the router tree, which
        // would otherwise re-read this /invite URL and accept the token again.
        navigate('/orgs', { replace: true });
        setActiveOrg(org.id);
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : 'Could not accept the invitation'));
  }, [token, reload, setActiveOrg, navigate]);

  return (
    <div style={pageStyle}>
      <h2 style={{ fontSize: '18px', color: '#c9d1d9', margin: 0 }}>Organisation invitation</h2>
      {error ? (
        <>
          <div style={{ fontSize: '13px', color: '#f85149' }} role="alert">{error}</div>
          <Link to="/orgs" style={{ fontSize: '13px', color: '#79c0ff' }}>Go to organisations</Link>
        </>
      ) : (
        <div style={{ fontSize: '13px', color: '#6e7681' }}>Accepting invitation…</div>
      )}
    </div>
  );
}

const pageStyle: React.CSSProperties = {
  maxWidth: '600px',
  margin: '0 auto',
  padding: '24px',
  display: 'flex',
  flexDirection: 'column',
  gap: '12px',
};
