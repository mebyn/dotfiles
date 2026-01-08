# (NVM_LAZY_LOAD set in ~/.zshrc)

# Define aliases
source ~/.aliases
source ~/.kubectl_aliases

# pipx user binaries
export PATH="$PATH:$HOME/.local/bin"

eval "$(/opt/homebrew/bin/brew shellenv)"

# Added by swiftly
. "/Users/melvin/.swiftly/env.sh"