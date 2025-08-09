#!/usr/bin/env bash
# Install git hooks for the micro-crystal project

echo "Installing Git hooks..."

# Configure Git to use the .githooks directory
git config core.hooksPath .githooks

if [ $? -eq 0 ]; then
    echo "✅ Git hooks installed successfully!"
    echo ""
    echo "The following hooks are now active:"
    for hook in .githooks/*; do
        if [ -f "$hook" ] && [ -x "$hook" ] && [ "$(basename $hook)" != "install.sh" ] && [ "$(basename $hook)" != "README.md" ]; then
            echo "  - $(basename $hook)"
        fi
    done
    echo ""
    echo "To disable hooks temporarily, run:"
    echo "  git config --unset core.hooksPath"
else
    echo "❌ Failed to install Git hooks"
    exit 1
fi