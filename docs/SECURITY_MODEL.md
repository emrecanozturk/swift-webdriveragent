# Security Model

SwiftWDA is a test automation component. It should run only on devices and hosts you control.

## Trust Boundary

The HTTP server accepts commands without built-in authentication. In production, expose it only through a trusted host process, local port forward, or authenticated device-farm gateway.

Do not expose the device port directly to untrusted networks.

## Sensitive Material

The repository must not contain:

- Apple certificates.
- Provisioning profiles.
- Private team identifiers.
- Device UDIDs.
- Customer app bundle ids.
- Internal host paths.

Use `Config/Signing.local.xcconfig` for local signing values. That file is ignored by git.

## Platform Boundaries

SwiftWDA uses XCTest automation APIs. It does not bypass iOS security controls, supervision policy, TCC prompts, app sandboxing, or device trust requirements.

Some optional runtime paths depend on selectors that are not guaranteed across iOS versions. Those paths are treated as best-effort and should be validated per device fleet.

## Reporting

Please see [SECURITY.md](../SECURITY.md) for vulnerability reporting.
