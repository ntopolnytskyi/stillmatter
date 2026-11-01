"""Non-shipped bounded JSONL lifecycle probe; a stub result is never model-quality evidence."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile
import time


class ProbeFailure(RuntimeError):
    pass


def run_child(command, cwd, env=None, timeout=15):
    records, buffer = [], b''
    with tempfile.TemporaryFile() as errors:
        child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=errors)
        try:
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            child.stdin.write(json.dumps({'id': 'probe-1', 'type': 'prompt',
                                          'message': 'Return only JSON: {"probe":"synthetic"}.'}).encode() + b'\n')
            child.stdin.flush()
            deadline = time.monotonic() + timeout
            settled = False
            while time.monotonic() < deadline and not settled:
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 1024 * 1024:
                    raise ProbeFailure('Oversized protocol record')
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    try:
                        record = json.loads(line.rstrip(b'\r'))
                    except (ValueError, UnicodeDecodeError) as error:
                        raise ProbeFailure('Malformed JSONL') from error
                    if not isinstance(record, dict):
                        raise ProbeFailure('Protocol record is not an object')
                    records.append(record)
                    if record.get('type') == 'agent_settled':
                        settled = True
            child.stdin.close()
            try:
                status = child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
                raise ProbeFailure('Child did not stop after stdin closed')
            if status:
                raise ProbeFailure(f'Child exited with status {status}')
            if not settled:
                raise ProbeFailure('No agent_settled before deadline/EOF; acknowledgement is not completion')
            acknowledgement = next((r for r in records if r.get('type') == 'response'
                                    and r.get('id') == 'probe-1' and r.get('command') == 'prompt'), None)
            if not acknowledgement or not acknowledgement.get('success'):
                raise ProbeFailure('Prompt not acknowledged successfully')
            messages = [r['message'] for r in records if r.get('type') == 'message_end'
                        and r.get('message', {}).get('role') == 'assistant']
            final = messages[-1] if messages else {}
            if final.get('stopReason') in ('error', 'aborted'):
                return {'accepted': True, 'settled': True, 'validArtifact': False,
                        'providerFailed': True, 'events': [r.get('type') for r in records]}
            content = ''.join(c.get('text', '') for c in final.get('content', []) if c.get('type') == 'text')
            try:
                artifact = json.loads(content)
            except ValueError:
                artifact = None
            return {'accepted': True, 'settled': True,
                    'validArtifact': artifact == {'probe': 'synthetic'},
                    'providerFailed': False, 'events': [r.get('type') for r in records]}
        finally:
            selector.close()
            if child.poll() is None:
                child.kill()
                child.wait()
            if not child.stdin.closed:
                child.stdin.close()
            child.stdout.close()


def actual_pi_unavailable_probe(pi):
    with tempfile.TemporaryDirectory(prefix='stillmatter-pi-capability-') as temporary:
        root = Path(temporary)
        agent = root / 'agent'
        agent.mkdir()
        (agent / 'models.json').write_text(json.dumps({'providers': {'local-probe': {
            'baseUrl': 'http://127.0.0.1:9/v1', 'api': 'openai-completions', 'apiKey': 'synthetic',
            'models': [{'id': 'missing-local-model', 'name': 'Missing local model probe',
                        'contextWindow': 4096, 'maxTokens': 256, 'reasoning': False,
                        'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}]}}}))
        (agent / 'settings.json').write_text(json.dumps({'retry': {'enabled': False}}))
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'PI_CODING_AGENT_DIR': str(agent),
               'PI_OFFLINE': '1', 'NO_COLOR': '1', 'TERM': 'dumb'}
        command = [pi, '--mode', 'rpc', '--no-session', '--no-tools', '--no-mcp',
                   '--no-extensions', '--no-context-files', '--no-skills', '--no-prompt-templates',
                   '--no-approve', '--offline', '--provider', 'local-probe', '--model', 'missing-local-model']
        return run_child(command, root, env=env, timeout=20)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pi', default=shutil.which('pi'))
    args = parser.parse_args()
    if not args.pi:
        parser.error('Pi executable unavailable')
    print(json.dumps(actual_pi_unavailable_probe(args.pi), indent=2))
