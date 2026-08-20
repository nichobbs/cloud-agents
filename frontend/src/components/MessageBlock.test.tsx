import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import type { Attachment, Message } from '../types';

vi.mock('../lib/api', () => ({
  api: {
    addTodo: vi.fn(),
    getAttachmentBlob: vi.fn(),
  },
}));

import { api } from '../lib/api';
import { MessageBlock } from './MessageBlock';

const message: Message = {
  id: 'm1',
  sessionId: 's1',
  role: 'user',
  content: 'here is a file',
  seq: '1',
  createdAt: '0',
};

function imageAttachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    id: 'a1',
    sessionId: 's1',
    messageId: 'm1',
    fileName: 'photo.png',
    mimeType: 'image/png',
    kind: 'image',
    sizeBytes: '1024',
    createdAt: '0',
    ...overrides,
  };
}

function documentAttachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    id: 'a2',
    sessionId: 's1',
    messageId: 'm1',
    fileName: 'report.pdf',
    mimeType: 'application/pdf',
    kind: 'document',
    sizeBytes: '2048',
    createdAt: '0',
    ...overrides,
  };
}

// jsdom doesn't implement these — MessageBlock's image path calls both.
// Direct reassignment (not vi.stubGlobal) so a real `URL` constructor is
// untouched for anything else that needs it.
const originalCreateObjectURL = URL.createObjectURL;
const originalRevokeObjectURL = URL.revokeObjectURL;

beforeEach(() => {
  vi.mocked(api.getAttachmentBlob).mockReset();
  URL.createObjectURL = vi.fn(() => 'blob:mock-url');
  URL.revokeObjectURL = vi.fn();
});

afterEach(() => {
  // Unmount (triggering AttachmentChip's revokeObjectURL cleanup effect)
  // WHILE the mocked URL methods are still in place — @testing-library's own
  // implicit auto-cleanup afterEach can run after this file's afterEach
  // hooks, by which point restoring the originals below would leave that
  // cleanup calling a real jsdom URL.revokeObjectURL that doesn't exist.
  cleanup();
  URL.createObjectURL = originalCreateObjectURL;
  URL.revokeObjectURL = originalRevokeObjectURL;
});

describe('MessageBlock attachments', () => {
  it('renders nothing extra for a message with no attachments', () => {
    render(<MessageBlock message={message} />);
    expect(screen.queryByTitle('report.pdf')).not.toBeInTheDocument();
    expect(screen.queryByTitle('photo.png')).not.toBeInTheDocument();
  });

  it('renders a document attachment as a download chip, fetched only on click', () => {
    render(<MessageBlock message={message} attachments={[documentAttachment()]} />);
    expect(screen.getByRole('button', { name: /report\.pdf/ })).toBeInTheDocument();
    // The document path is click-to-download, unlike images — it must not
    // eagerly fetch the bytes just to render the chip.
    expect(api.getAttachmentBlob).not.toHaveBeenCalled();
  });

  it('lazily fetches and renders an image attachment as a thumbnail', async () => {
    const blob = new Blob(['fake'], { type: 'image/png' });
    vi.mocked(api.getAttachmentBlob).mockResolvedValue(blob);
    render(<MessageBlock message={message} attachments={[imageAttachment()]} />);
    await waitFor(() => expect(api.getAttachmentBlob).toHaveBeenCalledWith('s1', 'a1'));
    await waitFor(() => expect(screen.getByAltText('photo.png')).toBeInTheDocument());
  });

  it('renders a placeholder without crashing if the image blob fetch fails', async () => {
    vi.mocked(api.getAttachmentBlob).mockRejectedValue(new Error('network error'));
    render(<MessageBlock message={message} attachments={[imageAttachment()]} />);
    await waitFor(() => expect(api.getAttachmentBlob).toHaveBeenCalled());
    // Still renders the link wrapper (title carries the fileName); no thumbnail.
    await waitFor(() => expect(screen.queryByAltText('photo.png')).not.toBeInTheDocument());
  });

  it('renders both an image thumbnail and a document chip when a message has both kinds', async () => {
    vi.mocked(api.getAttachmentBlob).mockResolvedValue(new Blob(['fake'], { type: 'image/png' }));
    render(<MessageBlock message={message} attachments={[imageAttachment(), documentAttachment()]} />);
    expect(screen.getByRole('button', { name: /report\.pdf/ })).toBeInTheDocument();
    await waitFor(() => expect(screen.getByAltText('photo.png')).toBeInTheDocument());
  });
});
