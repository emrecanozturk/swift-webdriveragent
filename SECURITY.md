# Security Policy

## Supported Versions

Security reports are accepted for the current `main` branch.

## Reporting a Vulnerability

Please use GitHub private vulnerability reporting when it is available for the repository. If that is not available, open a minimal public issue that says you have a security report to share, but do not include exploit details.

## Scope

In scope:

- Command injection or unsafe shell behavior in repository scripts.
- Exposure of signing material through checked-in files.
- HTTP server parsing issues that could affect trusted device-farm hosts.
- Documentation gaps that could cause unsafe public exposure.

Out of scope:

- Bypassing iOS platform security controls.
- Running the agent on devices you do not own or administer.
- Exposing the unauthenticated device server to untrusted networks.

## Security Expectations

SwiftWDA has no built-in HTTP authentication. Deploy it behind trusted host automation or an authenticated gateway.
