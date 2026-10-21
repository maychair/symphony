#!/usr/bin/env python3
"""Test-owned artifact policy. Symphony must treat this as an external tool."""
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[sys.argv.index('--input') + 1]).read_text())
record = payload['record']
axes = payload.get('axes', payload.get('result', {}).get('axes'))
assert isinstance(axes, dict) and set(axes) == {'standards', 'spec'}
findings = sum((axes[key]['findings'] for key in ('standards', 'spec')), [])
responses = sum((axes[key].get('responses', []) for key in ('standards', 'spec')), [])
status = 'changes_requested' if findings or any(v['status']=='still_valid' for v in responses) else 'passed'
if any(a['status'] == 'needs_input' for a in axes.values()): status = 'needs_input'
if any(a['status'] == 'failed' for a in axes.values()): status = 'failed'
body = 'LGTM!' if status == 'passed' else '\n\n'.join(a['report'] for a in axes.values())
result = dict(protocol=3, status=status, head=record['head'], base=record['base'], policy_sha=record['policy_sha'], axes=axes, findings=findings, responses=responses, body=body)
if 'result' in payload: assert result == payload['result']
print(json.dumps(result))
