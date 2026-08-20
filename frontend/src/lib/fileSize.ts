/** Human-readable file size ("512 B" / "2.0 KB" / "1.2 MB"). Returns '' for
 *  a non-finite or negative input rather than throwing — sizes coming from
 *  a server response (Attachment.sizeBytes is a string) or a client File
 *  object aren't guaranteed clean at every call site. */
export function formatFileSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
