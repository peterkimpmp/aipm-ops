# Contributing to aipm-ops

Thank you for your interest in contributing!

## How to Contribute

1. **Open an issue** describing the change you'd like to make.
2. **Fork** the repository and create a feature branch.
3. **Make your changes** following the conventions below.
4. **Open a pull request** referencing the issue.

## Conventions

### Commits

```
[AIPM-<n>] <type>(<scope>): <summary>

<description>

Refs #<n>
```

Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `research`

### Branch Naming

```
<type>/AIPM-<n>-<slug>
```

### Testing

Before submitting, verify your changes work:

```bash
# Dry-run bootstrap on a test repo
./scripts/aipm-bootstrap-repo.sh --repo /tmp/test-repo --dry-run

# Run audit
./scripts/aipm-audit-repos.sh --repo /tmp/test-repo
```

## Code of Conduct

Be respectful, constructive, and inclusive.
