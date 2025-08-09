# Git Hooks

This directory contains Git hooks for the micro-crystal project.

## Installation

Run the install script to configure Git to use these hooks:

```bash
./.githooks/install.sh
```

## Available Hooks

### pre-commit
- Enforces Crystal code formatting using `crystal tool format`
- Prevents commits with improperly formatted code
- Automatically shows which files need formatting

## Disabling Hooks

To temporarily disable hooks:

```bash
git config --unset core.hooksPath
```

To re-enable hooks:

```bash
git config core.hooksPath .githooks
```

## Manual Format Fix

If the pre-commit hook blocks your commit due to formatting issues:

```bash
crystal tool format
git add -A
git commit
```