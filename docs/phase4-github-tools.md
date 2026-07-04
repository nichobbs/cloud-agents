# Phase 4: GitHub Integration & Tool Packs

Goal: Integrate GitHub MCP server so Claude can interact with repos, issues, and PRs. Add customizable tool pack images.

Duration: 2 weeks

Implementation Details

1. GitHub MCP Server

Include @modelcontextprotocol/server-github in the base image (this is the
real published package — an earlier draft of this doc named a package,
`@anthropic/mcp-server-github`, that doesn't exist on npm). Generate
.claude/mcp.json on container startup — implemented in
`docker/mcp.json.template`, rendered by the entrypoint scripts:

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    }
  }
}
```

The GitHub PAT is injected from the user’s stored credentials. Placed in /workspace/.claude/mcp.json for session-specific use.

**Not yet implemented:** nothing in `src/docker_manager.l` actually sets a
`GITHUB_TOKEN` environment variable on the runner container, so the
substitution above always resolves to an empty token today — the GitHub MCP
server in every container can never authenticate. See
`docs/review-2026-07-03-followup.md` finding #1.

2. Frontend GitHub Panels

**Not yet implemented.** The frontend has no PR/issue/commit-fetching code —
this section describes the intended design, not shipped behavior (correctly
tracked as pending in `docs/PROGRESS.md`). The frontend would use the user’s
OAuth token directly to fetch PRs, issues, and commits from GitHub’s API.

3. Tool Packs (Docker Images)

Tag Extra packages Approx size
claude-code:base python3, node, lyric, dotnet, bash, make, git ~800 MB
claude-code:rust + cargo, rustc ~800 MB
claude-code:data + pandas, numpy, jupyter ~1.2 GB

Pre-built images pushed to a local registry or docker save/load on the server. User selects toolset at session creation.

4. Auto-Approval of Tools

Pre-generate .claude/settings.json per session with safe auto-approvals:

```json
{
  "permissions": {
    "allow": ["Read", "Bash(git:*)"]
  }
}
```

5. Constraints

· MCP server startup adds 1-2 seconds to cold start.
· GitHub PAT must have repo scope for PR/issue operations.
· Tool pack images increase disk usage; clean unused images periodically.

Rejected Alternatives

· Shared MCP server per user: More efficient but complicates isolation; per-session is simpler.
· On-demand tool installation: Slower cold start, versioning issues.

Deliverables

· Working GitHub MCP integration (Claude can create PRs, read issues).
· Frontend panels for PRs and issues.
· At least two tool pack images.
· Auto-approval configuration for safe operations.
