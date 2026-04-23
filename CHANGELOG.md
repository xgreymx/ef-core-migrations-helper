# Changelog

All notable changes to this project will be documented in this file.

The format is inspired by Keep a Changelog and the project follows Semantic Versioning.

## [Unreleased]

### Changed

- No unreleased changes yet.

## [0.2.2]

### Fixed

- Start captured EF command output on a fresh line after the spinner finishes.
- Preserve the configured nested migrations output directory when creating the first migration.

### Changed

- Expanded Smart App Control / Code Integrity troubleshooting guidance with clearer recovery status, reset emphasis, and a reference link for the known Windows 11 issue.
- Improved destructive command warnings for reset and targeted update flows.
- Added focused test coverage for spinner output handoff, migration output directory handling, and destructive warning rendering.
- Clarified README command usage for global installs (`efm ...`) versus local tool usage (`dotnet efm ...`), including the Windows `PATH` requirement for the global shim and the .NET 10 local manifest behavior.

## [0.2.1]

### Added

- Colored console banners for command execution and results.
- Spinner activity for captured EF commands.
- Highlighted migration and result lines in command output.

### Changed

- Improved console UX with safer no-spinner behavior for direct-stream build steps.
- Refined CIP recovery feedback around wrapped `dotnet ef` execution.

## [0.2.0]

### Added

- Windows CIP / Smart App Control auto-recovery for wrapped `dotnet ef` commands.
- `--no-auto-recover` and `EFM_NO_AUTO_RECOVER=1` opt-out controls.
- Recovery logging and xUnit coverage for the auto-recovery flow.
- Reset fallback support based on EF Core Design/Relational metadata and MSBuild target assembly resolution.

## [0.1.0]

### Added

- Initial public release with setup, named profiles, short EF Core commands, persisted configuration, and repository-local wrappers.