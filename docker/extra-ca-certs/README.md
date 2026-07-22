# Extra CA certificates for local builds

Drop your corporate/proxy root CA certificate(s) here (`.crt` or `.pem`,
PEM-encoded) before running `docker build`/`docker compose build` on a
network that does TLS interception — e.g. Zscaler, Netskope, or a similar
corporate proxy.

Each of the four Dockerfiles in this directory (`Dockerfile`,
`Dockerfile.codex`, `Dockerfile.opencode`, `Dockerfile.gemini`) copies
whatever is in this directory into its build stages' trust store before
making any outbound HTTPS call (`lyric restore`'s NuGet restore, `curl`
downloads of Lyric releases, `npm install -g`). Each build stage is its
own isolated container filesystem with its own CA trust store — a
corporate root CA trusted by your host OS/browser is NOT automatically
trusted inside these containers, so an intercepting proxy's re-signed
certificates fail chain validation there even though your host trusts
them fine (`NU1301: ... remote certificate is invalid ... PartialChain`
from `dotnet restore`, or `npm error code SELF_SIGNED_CERT_IN_CHAIN`,
are the usual symptoms).

Every stage that runs `npm install` also gets the cert(s) via
`NODE_EXTRA_CA_CERTS`, in addition to the OS-level trust store
(`update-ca-certificates`) — Node bundles its own CA store and does not
consult the OS one, so `update-ca-certificates` alone resolves `curl`/
`dotnet restore` but is NOT sufficient for `npm` to get past an
intercepting proxy (confirmed by testing against a real TLS-intercepting
proxy: `npm install` kept failing `SELF_SIGNED_CERT_IN_CHAIN` even after
`update-ca-certificates` reported the cert added to the OS store).

This directory is otherwise empty and gitignored except for this file —
files you add here are for your own local builds only and are never
committed. A build with no certs added here is unaffected (no-op).

To export your proxy's root CA on macOS: Keychain Access → find the
proxy's root certificate (e.g. "Zscaler Root CA") → File → Export Items…
→ save as a `.cer`/`.pem` file into this directory.
