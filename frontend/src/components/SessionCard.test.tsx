import { describe, it, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { SessionCard } from './SessionCard';
import type { Session } from '../types';

const baseSession: Session = {
  sessionId: 'test-session-12345678',
  repoUrl: 'https://github.com/example/repo',
  branch: 'main',
  createdAt: '1700000000000',
  status: 'IDLE',
};

describe('SessionCard', () => {
  it('renders repo label and branch', () => {
    render(
      <MemoryRouter>
        <SessionCard session={baseSession} />
      </MemoryRouter>
    );
    expect(screen.getByText('example/repo')).toBeInTheDocument();
    expect(screen.getByText('main')).toBeInTheDocument();
    expect(screen.queryByText(/thread/i)).not.toBeInTheDocument();
  });

  it('renders thread badge when parentSessionId is set', () => {
    const threadSession: Session = {
      ...baseSession,
      sessionId: 'child-session-87654321',
      parentSessionId: 'test-session-12345678',
    };
    render(
      <MemoryRouter>
        <SessionCard session={threadSession} />
      </MemoryRouter>
    );
    expect(screen.getByText('🧵 thread')).toBeInTheDocument();
  });
});
