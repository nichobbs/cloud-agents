import { describe, it, expect } from 'vitest';
import { parseGitHubUrl, summariseChecks, type CheckRun } from './github';

const run = (status: string, conclusion: string): CheckRun => ({
  name: 'ci',
  status,
  conclusion,
  htmlUrl: '',
});

describe('parseGitHubUrl', () => {
  it('parses owner/repo from https URLs, with and without .git', () => {
    expect(parseGitHubUrl('https://github.com/nichobbs/cloud-agents')).toEqual({
      owner: 'nichobbs',
      repo: 'cloud-agents',
    });
    expect(parseGitHubUrl('https://github.com/nichobbs/cloud-agents.git')).toEqual({
      owner: 'nichobbs',
      repo: 'cloud-agents',
    });
  });

  it('rejects non-GitHub hosts and malformed URLs', () => {
    expect(parseGitHubUrl('https://gitlab.com/a/b')).toBeNull();
    expect(parseGitHubUrl('https://github.com/only-owner')).toBeNull();
    expect(parseGitHubUrl('not a url')).toBeNull();
  });
});

describe('summariseChecks', () => {
  it('is none with no runs', () => {
    expect(summariseChecks([])).toBe('none');
  });

  it('is pending while any run is incomplete', () => {
    expect(summariseChecks([run('completed', 'success'), run('in_progress', '')])).toBe('pending');
  });

  it('is failing when any completed run failed', () => {
    expect(summariseChecks([run('completed', 'success'), run('completed', 'failure')])).toBe('failing');
    expect(summariseChecks([run('completed', 'timed_out')])).toBe('failing');
  });

  it('is passing when all completed runs succeeded or were skipped', () => {
    expect(summariseChecks([run('completed', 'success'), run('completed', 'skipped')])).toBe('passing');
  });
});
