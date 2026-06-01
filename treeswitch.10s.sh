#!/usr/bin/env zsh
#
# <xbar.title>treeswitch</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.author>Sindre Johannessen</xbar.author>
# <xbar.author.github>sindrej</xbar.author.github>
# <xbar.desc>Switch your local dev servers between git worktrees, right from the menu bar.</xbar.desc>
# <xbar.image>https://raw.githubusercontent.com/sindrej/treeswitch/main/docs/screenshot.png</xbar.image>
# <xbar.dependencies>zsh,git,swiftbar,gh</xbar.dependencies>
# <xbar.abouturl>https://github.com/sindrej/treeswitch</xbar.abouturl>
#
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
#
# treeswitch — SwiftBar plugin AND click-action dispatcher in one file.
#
#   - Run with no args  -> render the menu bar dropdown.
#   - Run with an action -> perform it (start / stop / stopall / restart /
#     resetmain / prsync / openlog / watch).
#
# SwiftBar runs this file on its refresh interval to draw the menu, and runs it
# again (with params) when you click an item.

# GUI apps get a minimal PATH, so set one that finds git/lsof + brew/uv/node.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SELF="${0:A}"                       # absolute path to this file (resolves symlink)
DATA="$HOME/.treeswitch"
CONF="$DATA/config.zsh"
STATE="$DATA/state"
LOGS="$DATA/logs"
mkdir -p "$STATE" "$LOGS" "$DATA/cache"

[[ -f "$CONF" ]] && source "$CONF"

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# pid(s) LISTENing on a tcp port
port_pid() { lsof -ti tcp:"$1" -sTCP:LISTEN 2>/dev/null }

# macOS notification
notify() { osascript -e "display notification \"$1\" with title \"treeswitch\"" >/dev/null 2>&1 }

# yes/no dialog — returns 0 only if the user clicks OK
confirm() {
  osascript -e "display dialog \"$1\" buttons {\"Cancel\",\"OK\"} default button \"OK\" with icon caution" >/dev/null 2>&1
}

# short git hint for a worktree: " ●" if dirty, " ↑n ↓n" vs upstream
wt_hint() {
  local wt="$1" hint="" ab a b
  [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null | head -1)" ]] && hint+=" ●"
  ab=$(git -C "$wt" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)
  if [[ -n "$ab" ]]; then
    b=${ab%%[[:space:]]*}; a=${ab##*[[:space:]]}
    [[ "$a" == <-> && "$a" != 0 ]] && hint+=" ↑$a"
    [[ "$b" == <-> && "$b" != 0 ]] && hint+=" ↓$b"
  fi
  print -r -- "$hint"
}

# emit "<path>\t<branch>" per worktree of a repo
list_worktrees() {
  local repo="$1" line p
  git -C "$repo" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "worktree "*) p="${line#worktree }" ;;
      "branch "*)   print -r -- "${p}"$'\t'"${line#branch refs/heads/}" ;;
      "detached")   print -r -- "${p}"$'\t'"(detached)" ;;
    esac
  done
}

# default branch of a repo (origin/HEAD, e.g. "main"; falls back to main/master)
default_branch() {
  local repo="$1" d b
  d=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  d=${d#origin/}
  if [[ -z "$d" ]]; then
    for b in main master; do
      git -C "$repo" show-ref --verify --quiet "refs/heads/$b" && { d=$b; break }
    done
  fi
  print -r -- "$d"
}

# path of the worktree checked out on the repo's default branch (empty if none)
main_worktree() {
  local repo="$1" def
  def="$(default_branch "$repo")"
  [[ -n "$def" ]] || return 0
  git -C "$repo" worktree list --porcelain 2>/dev/null | awk -v b="$def" '
    /^worktree /            { p = substr($0, 10) }
    /^branch refs\/heads\// { if ($0 == "branch refs/heads/" b) { print p; exit } }
  '
}

# ---------------------------------------------------------------------------
# process lifecycle
# ---------------------------------------------------------------------------

# Stop a repo's server: kill the whole process group we launched (so the
# uv-run/reloader parent and any ng-serve children die too), then fall back to
# whatever still holds the port. TERM first, KILL after ~3s.
stop_server() {
  local key="$1" port="${PORT[$key]}" pgid="" lp pids i
  [[ -f "$STATE/$key.pgid" ]] && pgid="$(cat "$STATE/$key.pgid")"

  # If we have no recorded group (e.g. server was started outside the tool),
  # derive the group from whoever holds the port.
  if [[ -z "$pgid" ]]; then
    lp=$(port_pid "$port" | head -1)
    [[ -n "$lp" ]] && pgid=$(ps -o pgid= -p "$lp" 2>/dev/null | tr -d ' ')
  fi

  [[ "$pgid" == <2-> ]] && kill -TERM -"$pgid" 2>/dev/null
  pids=$(port_pid "$port"); [[ -n "$pids" ]] && kill -TERM ${=pids} 2>/dev/null

  for i in {1..15}; do
    [[ -z "$(port_pid "$port")" ]] && break
    sleep 0.2
  done

  if [[ -n "$(port_pid "$port")" ]]; then           # still up → escalate
    [[ "$pgid" == <2-> ]] && kill -9 -"$pgid" 2>/dev/null
    pids=$(port_pid "$port"); [[ -n "$pids" ]] && kill -9 ${=pids} 2>/dev/null
  fi
}

do_start() {
  local key="$1" wt="$2"
  [[ -n "${REPO[$key]}" ]] || { echo "unknown repo: $key" >&2; return 1 }
  local port="${PORT[$key]}" log="$LOGS/$key.log"

  if [[ "${CONFIRM_KILL:-0}" == "1" && -n "$(port_pid "$port")" ]]; then
    confirm "Restart ${LABEL[$key]} (:$port) from ${wt:t}? This kills the running server." || return 0
  fi

  stop_server "$key"

  local dir="$wt"
  [[ -n "${WORKDIR[$key]}" && "${WORKDIR[$key]}" != "." ]] && dir="$wt/${WORKDIR[$key]}"

  [[ -f "$log" ]] && mv -f "$log" "$log.prev"     # rotate: one fresh log per launch
  print -r -- "===== $(date '+%Y-%m-%d %H:%M:%S')  start ${key} @ ${wt} =====" >> "$log"

  local cmd="cd ${(q)dir}"
  [[ "${NPM_INSTALL[$key]}" == "1" ]] && cmd+=" && { [[ -d node_modules ]] || npm install; }"
  cmd+=" && exec ${CMD[$key]}"

  # Launch in its OWN session/process group via setsid (perl is always present
  # on macOS). The leader's PID == the new PGID, so `kill -- -<pid>` later takes
  # down the entire tree. nohup + zsh -l keeps it alive with a login PATH.
  nohup perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV or die $!' /bin/zsh -lc "$cmd" >> "$log" 2>&1 &!
  local leader=$!
  print -r -- "$wt"     > "$STATE/$key.active"
  print -r -- "$leader" > "$STATE/$key.pgid"

  # detached readiness watcher → notify if the port never comes up
  nohup "$SELF" watch "$key" >/dev/null 2>&1 &!
}

do_stop() {
  local key="$1"
  if [[ "${CONFIRM_KILL:-0}" == "1" && -n "$(port_pid "${PORT[$key]}")" ]]; then
    confirm "Stop ${LABEL[$key]} (:${PORT[$key]})?" || return 0
  fi
  stop_server "$key"
  rm -f "$STATE/$key.active" "$STATE/$key.pgid"
}

do_stopall() {
  if [[ "${CONFIRM_KILL:-0}" == "1" ]]; then
    confirm "Stop ALL dev servers?" || return 0
  fi
  local key
  for key in $REPO_KEYS; do
    stop_server "$key"
    rm -f "$STATE/$key.active" "$STATE/$key.pgid"
  done
}

do_restart() {
  local key="$1" wt=""
  [[ -f "$STATE/$key.active" ]] && wt="$(cat "$STATE/$key.active")"
  [[ -n "$wt" ]] || { notify "No active worktree to restart for ${LABEL[$key]}"; return 1 }
  do_start "$key" "$wt"
}

# switch every repo to the worktree on its default (main) branch and start it
do_resetmain() {
  if [[ "${CONFIRM_KILL:-0}" == "1" ]]; then
    confirm "Switch ALL repos to their main worktree (restart on main)?" || return 0
  fi
  local CONFIRM_KILL=0      # confirmed once above; don't re-prompt per repo
  local key wt
  for key in $REPO_KEYS; do
    wt="$(main_worktree "${REPO[$key]}")"
    if [[ -n "$wt" ]]; then
      do_start "$key" "$wt"
    else
      notify "${LABEL[$key]}: no worktree on its main branch — skipped"
    fi
  done
}

# refresh the branch->PR cache for every repo (one `gh pr list` per repo).
# Runs detached/throttled from render so the menu never blocks on the network.
do_prsync() {
  mkdir -p "$DATA/cache"
  local key repo tmp
  for key in $REPO_KEYS; do
    repo="${REPO[$key]}"
    tmp="$DATA/cache/$key.prs.tmp"
    if ( cd "$repo" 2>/dev/null && gh pr list --state open \
           --json number,headRefName,isDraft \
           --jq '.[] | [.headRefName, (.number|tostring), (.isDraft|tostring)] | @tsv' ) > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$DATA/cache/$key.prs"
    else
      rm -f "$tmp"
    fi
  done
}

# poll up to ~25s for the port; notify if it never listens (and we weren't stopped)
do_watch() {
  local key="$1" port="${PORT[$key]}" i
  for i in {1..25}; do
    [[ -f "$STATE/$key.active" ]] || return 0      # stopped/switched meanwhile
    [[ -n "$(port_pid "$port")" ]] && return 0     # it's up
    sleep 1
  done
  [[ -f "$STATE/$key.active" ]] && notify "${LABEL[$key]} didn't come up on :$port — check the log"
}

do_openlog() {
  local key="$1" log="$LOGS/$key.log"
  [[ -f "$log" ]] || : > "$log"
  exec tail -n 300 -F "$log"
}

# ---------------------------------------------------------------------------
# menu rendering
# ---------------------------------------------------------------------------

render_menu() {
  local rkey rcount=0
  for rkey in $REPO_KEYS; do [[ -n "$(port_pid "${PORT[$rkey]}")" ]] && (( rcount++ )); done
  if (( rcount > 0 )); then
    print -r -- "${rcount} | sfimage=arrow.triangle.branch color=#3fb950"
  else
    print -r -- "| sfimage=arrow.triangle.branch"
  fi
  print -r -- "---"

  if [[ -z "$REPO_KEYS" ]]; then
    print -r -- "No config found | color=red"
    print -r -- "Expected: $CONF"
    return
  fi

  print -r -- "↩ Reset to main | bash=\"$SELF\" param1=resetmain terminal=false refresh=true"
  print -r -- "---"

  # kick off a background PR refresh if the cache is stale (non-blocking, throttled)
  if [[ "${SHOW_PRS:-1}" == "1" ]]; then
    local stamp="$DATA/cache/.lastsync"
    if [[ ! -f "$stamp" ]] || (( $(date +%s) - $(stat -f %m "$stamp") >= 120 )); then
      touch "$stamp"
      nohup "$SELF" prsync >/dev/null 2>&1 &!
    fi
  fi

  local -A PRMAP
  local key
  for key in $REPO_KEYS; do
    local port="${PORT[$key]}" active="" pid="" runtxt="" hdr_color="" url=""
    [[ -f "$STATE/$key.active" ]] && active="$(cat "$STATE/$key.active")"
    pid="$(port_pid "$port" | head -1)"
    if [[ -n "$pid" ]]; then runtxt="● running"; hdr_color="green"
    else runtxt="○ stopped"; hdr_color="#888888"; fi

    print -r -- "${LABEL[$key]} (:${port}) ${runtxt} | color=${hdr_color}"

    [[ -z "$pid" && -n "$active" ]] && \
      print -r -- "--⚠ not running — last start may have failed | color=orange"

    PRMAP=()
    if [[ "${SHOW_PRS:-1}" == "1" && -f "$DATA/cache/$key.prs" ]]; then
      local _b="" _n="" _d=""
      while IFS=$'\t' read -r _b _n _d; do
        [[ -n "$_b" ]] || continue
        [[ "$_d" == "true" ]] && PRMAP[$_b]="#$_n draft" || PRMAP[$_b]="#$_n"
      done < "$DATA/cache/$key.prs"
    fi

    local wpath="" wbranch="" mark="" c="" hint=""
    list_worktrees "${REPO[$key]}" | while IFS=$'\t' read -r wpath wbranch; do
      mark="   "; c=""
      if [[ "$wpath" == "$active" && -n "$pid" ]]; then mark="✓ "; c="color=green"; fi
      hint="$(wt_hint "$wpath")"
      print -r -- "--${mark}${wbranch}${PRMAP[$wbranch]:+  ${PRMAP[$wbranch]}}${hint}  —  ${wpath:t} | bash=\"$SELF\" param1=start param2=${key} param3=\"${wpath}\" terminal=false refresh=true ${c}"
    done

    print -r -- "-----"
    url="${OPEN_URL[$key]:-http://localhost:$port}"
    print -r -- "--Open ${url} | href=${url}"
    if [[ -n "$pid" ]]; then
      print -r -- "--↻ Restart current | bash=\"$SELF\" param1=restart param2=${key} terminal=false refresh=true"
      print -r -- "--Stop server | bash=\"$SELF\" param1=stop param2=${key} terminal=false refresh=true color=red"
    fi
    print -r -- "--Stream log | bash=\"$SELF\" param1=openlog param2=${key} terminal=true"
  done

  print -r -- "---"
  (( rcount > 0 )) && \
    print -r -- "Stop all | bash=\"$SELF\" param1=stopall terminal=false refresh=true color=red"
  print -r -- "Refresh | refresh=true"
  print -r -- "Edit config | bash=/usr/bin/open param1=-t param2=\"$CONF\" terminal=false"
}

# ---------------------------------------------------------------------------
# dispatch — scan args for a known action keyword (index-agnostic, so it works
# regardless of whether SwiftBar passes param1 as $1 or $0)
# ---------------------------------------------------------------------------

action=""; key=""; wt=""
for a in "$@"; do
  if [[ -z "$action" ]]; then
    case "$a" in start|stop|stopall|restart|resetmain|openlog|watch|prsync) action="$a" ;; esac
    continue
  fi
  if   [[ -z "$key" ]]; then key="$a"
  elif [[ -z "$wt"  ]]; then wt="$a"
  fi
done

case "$action" in
  start)   do_start "$key" "$wt" ;;
  stop)    do_stop "$key" ;;
  stopall) do_stopall ;;
  restart)   do_restart "$key" ;;
  resetmain) do_resetmain ;;
  prsync)  do_prsync ;;
  openlog) do_openlog "$key" ;;
  watch)   do_watch "$key" ;;
  *)       render_menu ;;
esac
