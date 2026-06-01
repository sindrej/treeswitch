#!/bin/zsh
# Non-destructive smoke test: syntax, clean menu rendering, and the action
# dispatcher — all against a throwaway $HOME and a throwaway git repo, so it
# never touches your real repos, ports, or SwiftBar install.
set -e
emulate -L zsh

SRC="${0:A:h}"
PLUGIN="$SRC/treeswitch.10s.sh"
fail() { print -r -- "FAIL: $1"; exit 1 }
ok()   { print -r -- "ok: $1" }

# 1) syntax
zsh -n "$PLUGIN" && ok "syntax"

# 2) sandbox HOME + a real git repo with a worktree
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"
mkdir -p "$HOME/.treeswitch/state" "$HOME/.treeswitch/logs"

# TWO repos, so the per-repo render loop iterates more than once — this is what
# surfaces zsh's "bare `local` on a re-declared var prints it" leak.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$TMP/wt-feature" -b feature >/dev/null 2>&1

cat > "$HOME/.treeswitch/config.zsh" <<EOF
typeset -gA LABEL REPO PORT CMD WORKDIR NPM_INSTALL OPEN_URL
REPO_KEYS=(demo demo2)
CONFIRM_KILL=0
SHOW_PRS=1
LABEL[demo]="Demo";   REPO[demo]="$REPO";   PORT[demo]=64999;  CMD[demo]="true";  WORKDIR[demo]="."; NPM_INSTALL[demo]=0
LABEL[demo2]="Demo2"; REPO[demo2]="$REPO";  PORT[demo2]=64998; CMD[demo2]="true"; WORKDIR[demo2]="."; NPM_INSTALL[demo2]=0
EOF

# Pre-seed the PR cache for BOTH repos and mark the sync stamp fresh, so the
# PR-rendering code path runs (without any real `gh` call) and the per-repo loop
# re-declares its locals — the conditions that surface the var-leak bug.
mkdir -p "$HOME/.treeswitch/cache"
touch "$HOME/.treeswitch/cache/.lastsync"
printf 'feature\t123\tfalse\n' > "$HOME/.treeswitch/cache/demo.prs"
printf 'feature\t123\tfalse\n' > "$HOME/.treeswitch/cache/demo2.prs"

# 3) menu renders, shows the PR number, and leaks NO bare "name=value" lines.
#    A leaked `local`/`typeset` print appears at line-start as `name=...`; every
#    real menu line starts with text/`-`/icon and only has `key=value` AFTER a `|`.
out="$(zsh "$PLUGIN")"
[[ "$out" == *"sfimage=arrow.triangle.branch"* ]] || fail "missing title/icon"
[[ "$out" == *"feature"* ]]                       || fail "worktree branch not listed"
[[ "$out" == *"#123"* ]]                          || fail "PR number not rendered"
leaked="$(print -r -- "$out" | grep -En '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
[[ -z "$leaked" ]] || fail "leaked shell variables into menu:
$leaked"
ok "menu renders cleanly (2 repos, PR numbers, no var leaks)"

# 4) dispatcher routes start/stop and writes/clears state (CMD=true, harmless)
zsh "$PLUGIN" start demo "$TMP/wt-feature"
[[ -f "$HOME/.treeswitch/state/demo.active" ]] || fail "start did not record active worktree"
[[ -f "$HOME/.treeswitch/state/demo.pgid" ]]   || fail "start did not record process group"
[[ "$(cat "$HOME/.treeswitch/state/demo.active")" == "$TMP/wt-feature" ]] || fail "wrong active path"
ok "start dispatch + state files"

zsh "$PLUGIN" stop demo
[[ ! -f "$HOME/.treeswitch/state/demo.active" ]] || fail "stop did not clear active"
[[ ! -f "$HOME/.treeswitch/state/demo.pgid" ]]   || fail "stop did not clear pgid"
ok "stop dispatch + state cleanup"

# 5) index-agnostic dispatch: a leading junk arg must not break routing
zsh "$PLUGIN" JUNK start demo "$TMP/wt-feature"
[[ -f "$HOME/.treeswitch/state/demo.active" ]] || fail "arg-scan failed with leading junk"
zsh "$PLUGIN" stop demo
ok "index-agnostic dispatch"

# 6) first-run welcome: with NO config the menu invites you to add a repo
#    (instead of a dead-end error) and still leaks no shell variables.
TMP2="$(mktemp -d)"
export HOME="$TMP2"                 # fresh sandbox, deliberately no config file
mkdir -p "$HOME/.treeswitch"
welcome="$(zsh "$PLUGIN")"
[[ "$welcome" == *"Add your first repo"* ]] || fail "welcome screen missing add-repo invite"
[[ "$welcome" == *"param1=addrepo"*       ]] || fail "welcome add-repo item not wired to addrepo"
leaked="$(print -r -- "$welcome" | grep -En '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
[[ -z "$leaked" ]] || fail "welcome screen leaked shell variables:
$leaked"
ok "first-run welcome screen"

# 7) visual "Add repo" wizard logic — stub the native dialogs so NO GUI pops,
#    then assert it writes a sourceable config block for the new repo.
GITREPO="$TMP2/myapp"; mkdir -p "$GITREPO"; git -C "$GITREPO" init -q
zsh <<TEST
  source "$PLUGIN" >/dev/null 2>&1          # defines funcs; renders welcome (discarded)
  ask_folder() { print -r -- "$GITREPO" }
  ask_text()   {
    case "\$1" in
      *Name*)    print -r -- "My Cool App" ;;
      *port*)    print -r -- 4321 ;;
      *Command*) print -r -- "npm run dev" ;;
    esac
  }
  alert()  { : }   # never expect to hit validation
  notify() { : }
  do_addrepo
TEST
[[ -f "$HOME/.treeswitch/config.zsh" ]] || fail "addrepo did not create a config"
probe="$(zsh -c 'source "$HOME/.treeswitch/config.zsh"
  print -r -- "KEYS=$REPO_KEYS"
  print -r -- "PATH=${REPO[my-cool-app]}"
  print -r -- "PORT=${PORT[my-cool-app]}"
  print -r -- "NPMI=${NPM_INSTALL[my-cool-app]}"')"
[[ "$probe" == *"KEYS=my-cool-app"*   ]] || fail "addrepo did not register the repo key
$probe"
[[ "$probe" == *"PATH=$GITREPO"*      ]] || fail "addrepo wrote the wrong repo path
$probe"
[[ "$probe" == *"PORT=4321"*          ]] || fail "addrepo wrote the wrong port
$probe"
[[ "$probe" == *"NPMI=1"*             ]] || fail "addrepo failed to infer npm install
$probe"
ok "visual add-repo wizard writes a valid config"

print -r -- ""
print -r -- "ALL PASSED"
