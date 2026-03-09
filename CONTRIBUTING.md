# Contributing to SqlCipherKit

Thank you for considering a contribution!

## Reporting Issues

Before opening a new issue, search the existing issues to avoid duplicates. When filing a bug, please include:

- A concise description of the problem.
- The SqlCipherKit version (or commit SHA).
- The Swift version and platform (`swift --version`, macOS/iOS/Linux).
- A minimal, self-contained reproduction — ideally a failing test case.

For **security vulnerabilities**, please follow the process described in [SECURITY.md](SECURITY.md) rather than opening a public issue.

## Pull Requests

1. **Fork** the repository and create a branch from `main`.
2. **Write tests** that cover the changed behaviour. PRs without tests will not be merged (unless the change is docs-only or trivial).
3. **Run the full test suite** locally before pushing:
   ```bash
   swift test
   ```
4. **Run the linter** to catch style issues early:
   ```bash
   swiftlint lint
   swiftformat --lint .
   ```
5. **Update the changelog** — add an entry under `[Unreleased]` in `CHANGELOG.md` describing your change.
6. Open the PR against `main`. Fill out the pull-request template and link to any related issues.

## Code Style

- The project uses **SwiftLint** and **SwiftFormat**; both run automatically in CI. See `.swiftlint.yml` and `.swiftformat` for the configured rules.
- Prefer small, focused PRs. Large refactors should be discussed in an issue first.
- All public symbols require documentation comments (`///`).

## Legal

By submitting a pull request you agree that your contribution is licensed under the same [MIT License](LICENSE) that covers the project.
