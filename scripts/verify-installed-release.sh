#!/usr/bin/env bash
# verify-installed-release.sh — honest closed loop for "installed == released == fixed".
#
# Checks, in order, all against live state (nothing asserted from memory):
#   1. GitHub release <tag> exists and its DMG asset URL is downloadable
#   2. /Applications/ocoreai.app version string == <tag>  (installed is current)
#   3. cold-boot perception: with persisted network=false (and others true),
#      a freshly launched app's observe_state reports NO [network] frames,
#      and with network=true it DOES — proves boot hook + lever honesty on
#      the shipped bundle, no GUI touches (the cold-boot gap, fixed 14d2ab5).
# Any check that cannot run prints SKIP with a reason, never fakes PASS.
#
# Usage: TAG=v0.1.9 bash scripts/verify-installed-release.sh
set -uo pipefail
TAG="${TAG:-}"
[ -n "$TAG" ] || { echo "usage: TAG=vX.Y.Z bash scripts/verify-installed-release.sh"; exit 2; }
REPO="uingei/ocoreai"
APP=/Applications/ocoreai.app
DOMAIN=com.ocoreai.ocoreai
FAIL=0
note(){ echo "[$1] $2"; }

# 1. release asset exists upstream
ASSET=$(curl -s "https://api.github.com/repos/$REPO/releases/tags/$TAG" | python3 -c "
import json,sys
d=json.load(sys.stdin)
a=[x for x in d.get('assets',[]) if x['name'].endswith('.dmg')]
print(a[0]['browser_download_url'] if a else 'NO_ASSET')
" 2>/dev/null)
if [ "$ASSET" = "NO_ASSET" ] || [ -z "$ASSET" ]; then
  note FAIL "no DMG asset published for $TAG yet"; FAIL=1
else
  SHA_REMOTE=$(curl -s "https://api.github.com/repos/$REPO/git/ref/tags/$TAG" | python3 -c "import json,sys;print(json.load(sys.stdin).get('object',{}).get('sha','')[:9])" 2>/dev/null)
  note PASS "release $TAG published, asset=$ASSET, tag-sha=${SHA_REMOTE:-unknown}"
fi

# 2. installed version matches tag
V=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)
if [ "v$V" = "$TAG" ]; then note PASS "installed version = $V"; else note FAIL "installed=$V expected ${TAG#v}"; FAIL=1; fi

# helper: relaunch installed app cleanly
launch(){ 
  for p in $(pgrep -f "$APP/Contents/MacOS" 2>/dev/null); do kill -TERM "$p"; done; sleep 3
  for p in $(pgrep -f "$APP/Contents/MacOS" 2>/dev/null); do kill -9 "$p"; done; sleep 1
  OCOREAI_ENABLE_HTTP=1 OCOREAI_APPROVAL_POLICY=auto open -n "$APP"
  local ok=0; for _ in $(seq 1 40); do curl -s -m 3 http://127.0.0.1:8080/health >/dev/null 2>&1 && { ok=1; break; }; sleep 2; done
  [ "$ok" = 1 ]
}

ask_channels(){ # prints observed bracket tags from observe_state via live tools
  curl -s -m 10 http://127.0.0.1:8080/v1/tools > /tmp/vir_tools.json 2>/dev/null
  python3 - <<'EOF'
import json
tools=json.load(open('/tmp/vir_tools.json'))
tools=tools.get('data',tools) if isinstance(tools,dict) else tools
req={'model':'mlx-community/gemma-4-e2b-it-4bit',
 'messages':[{'role':'user','content':'Use the observe_state tool. Report the bracketed channel tags you see.'}],
 'tools':tools,'max_tokens':250,'stream':False}
json.dump(req,open('/tmp/vir_req.json','w'))
EOF
  curl -s -m 300 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d @/tmp/vir_req.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
ch=d.get('choices')
print((ch[0]['message'].get('content') or '') if ch else 'REQUEST_FAILED:'+json.dumps(d)[:120])
"
}

# 3. cold-boot A/B, persisted votes only, zero GUI touches
defaults write $DOMAIN settings.perception.enabled -bool true
defaults write $DOMAIN settings.perception.filesystem -bool true
defaults write $DOMAIN settings.perception.network -bool true

if launch && sleep 35; then
  A=$(ask_channels)
  echo "    A(n=ON ) => $A"
  defaults write $DOMAIN settings.perception.network -bool false
  if launch && sleep 35; then
    B=$(ask_channels)
    echo "    B(n=OFF) => $B"
    case "$A" in *network*) note PASS "cold boot network ON -> [network] observed";; *) note FAIL "network voted ON but absent: $A"; FAIL=1;; esac
    case "$B" in *network*) note FAIL "network voted OFF but still present: $B"; FAIL=1;; *) note PASS "cold boot network OFF -> channel gone";; esac
    case "$B" in *environment*) note PASS "fs/environment still flows (lever is scoped)";; *) note SKIP "fs channel not echoed; cannot assert scoping";; esac
  else
    note FAIL "relaunch B failed"; FAIL=1
  fi
else
  note FAIL "launch A failed"; FAIL=1
fi

# final: restore sane defaults, leave app running for the user
defaults write $DOMAIN settings.perception.network -bool true
[ $FAIL -eq 0 ] && echo "ALL_HONEST: installed == released == behaves-as-voted" || echo "NOT_DELIVERED: $FAIL checks failed"
exit $FAIL
