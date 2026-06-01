# treeswitch configuration  (example)
#
# On first install this is copied to ~/.treeswitch/config.zsh — edit THAT copy
# (the menu's "Edit config" item opens it). Add a repo by appending its key to
# REPO_KEYS and filling in the matching array entries below.

typeset -gA LABEL REPO PORT CMD WORKDIR NPM_INSTALL OPEN_URL
REPO_KEYS=(frontend backend)

# Confirm before killing a running server (0 = off, 1 = on).
CONFIRM_KILL=0
# Show GitHub PR numbers next to worktree branches (needs `gh`; 0 = off, 1 = on).
SHOW_PRS=1

# --- Example: a frontend dev server on :4200 -----------------------------
LABEL[frontend]="Frontend"
REPO[frontend]="$HOME/code/your-frontend-repo"
PORT[frontend]=4200
CMD[frontend]="npm start"
WORKDIR[frontend]="."          # run CMD from this subdir of the worktree
NPM_INSTALL[frontend]=1        # run `npm install` first if node_modules is missing
OPEN_URL[frontend]="http://localhost:4200"

# --- Example: a backend dev server on :8000 ------------------------------
LABEL[backend]="Backend"
REPO[backend]="$HOME/code/your-backend-repo"
PORT[backend]=8000
CMD[backend]="uv run uvicorn main:app --reload"
WORKDIR[backend]="."
NPM_INSTALL[backend]=0
OPEN_URL[backend]="http://localhost:8000/docs"
