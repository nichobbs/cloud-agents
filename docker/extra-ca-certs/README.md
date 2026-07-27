# Extra CA certificates for local builds

Drop your corporate/proxy root CA certificate(s) here (`.crt`, `.pem`, or
`.cer`, PEM-encoded) before running `docker build`/`docker compose build`
on a network that does TLS interception — e.g. Zscaler, Netskope, or a
similar corporate proxy.

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

A dropped file may contain a single certificate or a whole bundle (a root +
intermediate chain, or several unrelated CAs concatenated) — each build
splits it into one certificate (or CRL) per file (`docker/split-ca-bundle.sh`)
before handing it to `update-ca-certificates`, so a bundle doesn't trigger
its `does not contain exactly one certificate or CRL` warning or leave
anything past the first entry un-hashed.

Give files distinct basenames (`corp-root.crt`, `corp-intermediate.pem`,
not `corp.crt` and `corp.pem`) — the destination filename is derived from
the source basename with its extension stripped, so two files that only
differ by extension collide on the same prefix and one silently
overwrites (or, for a multi-cert bundle, partially interleaves with) the
other's output.

This directory is otherwise empty and gitignored except for this file —
files you add here are for your own local builds only and are never
committed. A build with no certs added here is unaffected (no-op).

To export your proxy's root CA on macOS: Keychain Access → find the
proxy's root certificate (e.g. "Zscaler Root CA") → File → Export Items…
→ save as a `.cer`, `.pem`, or `.crt` file into this directory.

Any cert dropped in here is baked into the built image's layers (not
stripped out afterward) — deliberately, so the ephemeral runner
containers themselves also trust the same proxy at runtime, not just the
build. A CA certificate is a public key, not a secret, so this carries no
confidentiality risk on its own; it does mean you should avoid pushing an
image built this way to a registry outside your organization (npm-network
proxy config generally shouldn't leak either way, but there's no reason
to publish it).
