"""Read-only review transport: bounded UTF-8 pages, with explicit opaque hex data.

Run inside the native sandbox. No files, caches or subprocess output are written.
Only quoted, entirely hexadecimal 0x strings may be represented as opaque data;
all surrounding source and all other strings are preserved verbatim.
"""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

PAGE = 16384
STRINGS = re.compile(r'"[^"\\]*(?:\\.[^"\\]*)*"')
HEX = re.compile(r'"0x[0-9a-fA-F]{4096,}"\Z')


def structural(line):
    def replace(match):
        value = match.group()
        if not HEX.fullmatch(value) or (len(value) - 4) % 2:
            return value
        data = bytes.fromhex(value[3:-1])
        return ('"<opaque-hex bytes=' + str(len(data)) +
                ' sha256=' + hashlib.sha256(data).hexdigest() +
                ' prefix=' + value[1:35] + ' suffix=' + value[-33:-1] +
                '; inspect original with representation=raw>"')
    return STRINGS.sub(replace, line)


def read(request):
    kind = request['kind']
    if kind == 'file':
        root = Path.cwd().resolve()
        relative = Path(request['path'])
        target = (root / relative).resolve(strict=True)
        if (relative.is_absolute() or '..' in relative.parts or '.git' in relative.parts
                or not target.is_relative_to(root) or '.git' in target.relative_to(root).parts
                or not target.is_file()):
            raise ValueError('review_path_not_readable')
        stream = target.open('rb')
        process = None
    else:
        commands = {
            'diff': ['git', 'diff', '--no-ext-diff', '--no-textconv', request['base'], request['head'], '--'],
            'list': ['git', 'ls-files'],
            'commits': ['git', 'log', '--format=%H%n%B', request['base'] + '..' + request['head']],
        }
        process = subprocess.Popen(commands[kind], stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        stream = process.stdout
    offset = request.get('offset', 0)
    if type(offset) is not int or offset < 0:
        raise ValueError('invalid_read_offset')
    representation = request.get('representation', 'structural')
    if representation not in ('structural', 'raw'):
        raise ValueError('invalid_read_representation')
    total = raw_total = 0
    digest = hashlib.sha256()
    page = bytearray()
    try:
        for raw in stream:
            line = raw.decode('utf-8')
            raw_total += len(raw)
            digest.update(raw)
            data = (structural(line) if representation == 'structural' and kind in ('diff', 'file') else line).encode('utf-8')
            start = max(0, offset - total)
            if start < len(data) and len(page) < PAGE + 4:
                page.extend(data[start:start + PAGE + 4 - len(page)])
            total += len(data)
        if process is not None and process.wait() != 0:
            raise ValueError('review_command_failed')
    finally:
        stream.close()
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
    if offset > total:
        raise ValueError('invalid_read_offset')
    page = bytes(page[:PAGE])
    while page:
        try:
            content = page.decode('utf-8')
            break
        except UnicodeDecodeError as error:
            if error.start < len(page) - 3 or error.reason != 'unexpected end of data':
                raise
            page = page[:error.start]
    else:
        content = ''
    finish = offset + len(page)
    return dict(kind=kind, path=request.get('path'), representation=representation,
                offset=offset, next_offset=finish if finish < total else None,
                total_bytes=total, raw_bytes=raw_total, raw_sha256=digest.hexdigest(), content=content)


if __name__ == '__main__':
    try:
        print(json.dumps(read(json.loads(sys.argv[1])), ensure_ascii=False))
    except (ValueError, OSError, KeyError) as error:
        print(type(error).__name__ + ': review input unavailable', file=sys.stderr)
        sys.exit(1)
