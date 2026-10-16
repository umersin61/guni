#!/usr/bin/env sh
# Inline deployments/sepolia.json into the frontend template → frontend/index.html
set -e
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
cfg=json.load(open('deployments/sepolia.json'))
t=open('frontend/index.template.html').read()
open('frontend/index.html','w').write(t.replace('__DEPLOYMENT__',json.dumps(cfg,indent=2)))
print('frontend/index.html built for gUNI', cfg['guni'])
PY
