# Phase 3: Multi-Tenancy & Security (with GitHub OAuth)

Goal: Secure the API so each user accesses only their own sessions and credentials, using the existing GitHub OAuth identity.

Duration: 1 week

Implementation Details

1. Authentication Middleware

Every API request expects:

```
Authorization: Bearer <github_access_token>
```

Middleware:

1. Extracts the token.
2. Calls https://api.github.com/user with that token.
3. On success, stores the GitHub user id and login in request context.
4. On failure, returns 401.

Cache validation results for token lifetime (TTL ~1 hour) to reduce latency. No sessions, no JWT, no password database.

2. Per-User Resources

All resources are keyed by GitHub user ID:

· Docker volumes: user-<githubId>-home, session-<githubId>-<sessionId>.
· Database queries always filter by github_user_id.

3. Credential Upload

Endpoint: PUT /api/users/me/credentials

· Requires GitHub token.
· Accepts multipart upload of .claude folder (tar.gz).
· Encrypts the blob with server-side key + GitHub user ID as associated data.
· Stores as credentials/<githubId>.enc.

On container start:

· Decrypt the blob to a temporary directory.
· Mount it into the container at /home/claude-user/.claude (read-write for history).
· After container exit, securely wipe the temp directory.

The GitHub token is never stored. The encryption key lives only in server environment variables.

4. Session Ownership Enforcement

All session queries include WHERE github_user_id = ?. If the authenticated user does not match the session’s owner, the server returns 403.

5. GitHub API Access for Frontend

The frontend uses the same OAuth token to call GitHub’s API directly for repo data (PRs, issues, commits). No need to proxy through our API server. The OAuth scopes granted (repo, read:user) cover both identity verification and repository access.

6. No Separate User Registration

No sign-up flow. Any user with a valid GitHub token and Claude subscription can use the platform after uploading credentials. For access restriction, maintain a whitelist of GitHub IDs in an environment variable.

Constraints

· Token must have read:user scope (your OAuth app already requests this).
· Validation adds ~100-200ms per request (mitigated by caching).
· Credential decryption adds minimal overhead per container start.

Rejected Alternatives

· Separate API keys per user: Additional key management, unnecessary.
· GitHub token as encryption key: Token expires, making stored credentials unrecoverable.
· User database linked to GitHub ID: Unnecessary overhead.

Deliverables

· Authentication middleware that validates GitHub tokens.
· Credential upload, encrypted storage, and container injection.
· Session ownership checks.
· Token validation caching.
