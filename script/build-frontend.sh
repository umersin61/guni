#!/usr/bin/env sh
# Inline deployments/sepolia.json into the frontend template → frontend/index.html
set -e
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json
cfg=json.load(open('deployments/sepolia.json'))
t=open('frontend/index.template.html').read()
out=t.replace('__DEPLOYMENT__',json.dumps(cfg,indent=2))
open('frontend/index.html','w').write(out)
import os; os.makedirs('docs',exist_ok=True); open('docs/index.html','w').write(out)
print('frontend/index.html built for gUNI', cfg['guni'])
PY
