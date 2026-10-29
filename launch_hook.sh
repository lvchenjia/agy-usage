#!/bin/bash
# Consume stdin only if non-interactive pipe
if [ ! -t 0 ]; then
    cat > /dev/null
fi

# Persist CSRF token if available
if [[ -n "$ANTIGRAVITY_CSRF_TOKEN" ]]; then
    echo -n "$ANTIGRAVITY_CSRF_TOKEN" > /tmp/agy_csrf_token
    echo -n "$ANTIGRAVITY_CSRF_TOKEN" > "$HOME/.gemini/antigravity-cli/.csrf_token" 2>/dev/null
fi

# Ensure Agy Usage menu bar app is running
if ! pgrep -fl "AgyUsage" > /dev/null 2>&1; then
    open "/Applications/Agy Usage.app"
fi

echo "{}"
