# SwiftWDA Wiki

Welcome to the SwiftWDA wiki. This wiki is the operator-facing guide for building, signing, launching, integrating, and maintaining the Swift XCTest runner.

## Start Here

- [Quick Start](Quick-Start)
- [Build and Signing](Build-and-Signing)
- [API and Compatibility](API-and-Compatibility)
- [Operations](Operations)

## Architecture

- [Architecture](Architecture)
- [Security](Security)
- [FAQ](FAQ)

## Repository

- Source documentation lives in `docs/`.
- Wiki source lives in `docs/wiki/`.
- Publish the wiki with `scripts/publish-wiki.sh` after the GitHub repository exists.

## What SwiftWDA Is

SwiftWDA is a Swift-native XCTest runner that exposes a WebDriverAgent-compatible HTTP surface. It is intentionally compact, observable, and generic enough for public release and private device-farm adaptation.
