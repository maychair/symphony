#!/usr/bin/env python3
"""Local OMP protocol peer. Never contacts a model or an external service."""
import base64
import json
import pathlib
import sys

root = pathlib.Path(__file__).parent
mode_path = root / 'mode'
state = {'sessionId': 'session', 'sessionFile': str(root / 'transcript'),
         'isSettled': True, 'messageCount': 1, 'model': None}
(root / 'transcript').write_text('transcript\n')

def emit(value):
    print(json.dumps(value), flush=True)

def mode():
    return mode_path.read_text() if mode_path.exists() else ''

def chunked(value, kind):
    data = json.dumps(value).encode()
    parts = [data[:len(data)//2], data[len(data)//2:]]
    for index, part in enumerate(parts):
        chunk = {'type': 'rpc_chunk', 'index': index, 'chunkId': 'fixture',
                 'count': 2, 'byteLength': len(data), 'data': base64.b64encode(part).decode()}
        if kind == 'invalid': chunk['data'] = '?'
        if kind == 'size': chunk['byteLength'] += 1
        if kind == 'sequence' and index == 1: chunk['chunkId'] = 'different'
        emit(chunk)

emit({'type': 'ready'})
for line in sys.stdin:
    command = json.loads(line)
    kind = command['type']
    current = mode()
    ident = command.get('id')
    if kind == 'prompt':
        current = command['message']
        if current == 'rejected':
            emit({'type': 'response', 'id': ident, 'success': False, 'error': 'rejected'})
        elif current == 'overflow': emit({'type': 'rpc_frame_error'})
        elif current == 'input': emit({'type': 'extension_ui_request'})
        elif current == 'exit': sys.exit(9)
        elif current == 'hang': pass
        elif current.startswith('chunk:'):
            chunked({'type': 'prompt_result', 'id': ident, 'status': 'completed', 'sessionSettled': True}, current.split(':')[1])
        elif current.startswith('host:'):
            prompt_id = ident
            emit({'type': 'host_tool_call', 'id': 'tool', 'toolName': current.split(':')[1], 'arguments': {}})
        else:
            emit({'type': 'prompt_result', 'id': ident, 'status': 'aborted', 'sessionSettled': True})
    elif kind == 'host_tool_result':
        emit({'type': 'prompt_result', 'id': prompt_id, 'status': 'aborted', 'sessionSettled': True})
    elif current == 'fail:' + kind:
        emit({'type': 'response', 'id': ident, 'success': False, 'error': 'fixture failure'})
    else:
        if kind == 'get_state':
            if current == 'busy': state['isSettled'] = False
            if current == 'missing-id': state['sessionId'] = None
            if current == 'model': state['model'] = {'id': 'changed'}
        if current == 'noise':
            print('not-json', flush=True)
            emit({'type': 'notice', 'padding': 'x' * 1100000})
        emit({'type': 'response', 'id': ident, 'success': True,
              'data': state if kind == 'get_state' else {}})
