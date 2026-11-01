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
from urllib.parse import urlsplit


class ProbeFailure(RuntimeError):
    pass


def run_child(command, cwd, env=None, timeout=15, max_record_bytes=1024 * 1024,
              max_output_bytes=4 * 1024 * 1024, prompt=None,
              expected_artifact=None):
    """Observe one isolated prompt; bounds apply to stdout and stderr together."""
    records, buffer = [], b''
    output_bytes = 0
    settled = handled = False
    child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    try:
        selector.register(child.stdout, selectors.EVENT_READ)
        selector.register(child.stderr, selectors.EVENT_READ)
        child.stdin.write(json.dumps({'id': 'probe-1', 'type': 'prompt',
                                      'message': prompt or 'Return only JSON: {"probe":"synthetic"}.'}).encode() + b'\n')
        child.stdin.flush()
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeFailure('Child exceeded process deadline')
            ready = selector.select(remaining)
            for key, _ in ready:
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output_bytes += len(chunk)
                if output_bytes > max_output_bytes:
                    raise ProbeFailure('Child exceeded output byte limit')
                if key.fileobj is child.stderr:
                    continue  # Drain separately; diagnostics are never protocol or artifact text.
                buffer += chunk
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    if len(line) > max_record_bytes:
                        raise ProbeFailure('Oversized protocol record')
                    try:
                        record = json.loads(line.rstrip(b'\r'))
                    except (ValueError, UnicodeDecodeError) as error:
                        raise ProbeFailure('Malformed JSONL') from error
                    if not isinstance(record, dict):
                        raise ProbeFailure('Protocol record is not an object')
                    records.append(record)
                    if record.get('type') == 'agent_settled':
                        settled = True
                    if (record.get('type') == 'response' and record.get('id') == 'probe-1'
                            and record.get('command') == 'prompt' and record.get('success') is True
                            and isinstance(record.get('data'), dict)
                            and record['data'].get('disposition') == 'handled'):
                        handled = True
                    if (settled or handled) and not child.stdin.closed:
                        child.stdin.close()
                if len(buffer) > max_record_bytes:
                    raise ProbeFailure('Oversized protocol record')
        if buffer:
            raise ProbeFailure('Truncated JSONL record at EOF')
        if not child.stdin.closed:
            child.stdin.close()
        try:
            status = child.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise ProbeFailure('Child exceeded process deadline') from error
        if status:
            raise ProbeFailure(f'Child exited with status {status}')
        acknowledgement = next((r for r in records if r.get('type') == 'response'
                                and r.get('id') == 'probe-1' and r.get('command') == 'prompt'), None)
        if not acknowledgement or acknowledgement.get('success') is not True:
            raise ProbeFailure('Prompt not acknowledged successfully')
        if not settled and not handled:
            raise ProbeFailure('No agent_settled before deadline/EOF; acknowledgement is not completion')
        messages = [r['message'] for r in records if r.get('type') == 'message_end'
                    and isinstance(r.get('message'), dict) and r['message'].get('role') == 'assistant']
        final = messages[-1] if messages else {}
        aborted = any(r.get('aborted') is True for r in records if r.get('type') == 'agent_settled')
        provider_failed = final.get('stopReason') in ('error', 'aborted')
        content = final.get('content', [])
        if not isinstance(content, list) or any(not isinstance(c, dict) for c in content):
            raise ProbeFailure('Malformed assistant content')
        texts = [c.get('text', '') for c in content if c.get('type') == 'text']
        if any(not isinstance(value, str) for value in texts):
            raise ProbeFailure('Malformed assistant text')
        try:
            artifact = json.loads(''.join(texts))
        except ValueError:
            artifact = None
        return {'accepted': True, 'settled': settled, 'handled': handled, 'aborted': aborted,
                'validArtifact': (settled and not handled and not aborted and not provider_failed
                                  and final.get('stopReason') != 'length'
                                  and artifact == (expected_artifact if expected_artifact is not None
                                                   else {'probe': 'synthetic'})),
                'artifact': artifact, 'assistantText': ''.join(texts),
                'finalStopReason': final.get('stopReason'),
                'providerFailed': provider_failed, 'events': [r.get('type') for r in records]}
    finally:
        selector.close()
        if child.poll() is None:
            child.kill()
            child.wait()
        if not child.stdin.closed:
            child.stdin.close()
        child.stdout.close()
        child.stderr.close()


def actual_pi_local_probe(pi, base_url, model, prompt=None, expected_artifact=None, timeout=20):
    endpoint = urlsplit(base_url)
    if (endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1"
            or endpoint.username or endpoint.password or endpoint.path != "/v1"
            or endpoint.query or endpoint.fragment):
        raise ProbeFailure("Only literal HTTP loopback /v1 providers are allowed")
    with tempfile.TemporaryDirectory(prefix='stillmatter-pi-capability-') as temporary:
        root = Path(temporary)
        agent = root / 'agent'
        agent.mkdir()
        (agent / 'models.json').write_text(json.dumps({'providers': {'local-probe': {
            'baseUrl': base_url, 'api': 'openai-completions', 'apiKey': 'synthetic',
            'models': [{'id': model, 'name': 'Synthetic local model probe',
                        'contextWindow': 8192, 'maxTokens': 512, 'reasoning': False,
                        'samplingParams': {'temperature': 0, 'seed': 42},
                        'input': ['text'], 'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0}}]}}}))
        (agent / 'settings.json').write_text(json.dumps({'retry': {'enabled': False},
            'compaction': {'enabled': False, 'reserveTokens': 512, 'keepRecentTokens': 1024}}))
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'PI_CODING_AGENT_DIR': str(agent),
               'PI_OFFLINE': '1', 'NO_COLOR': '1', 'TERM': 'dumb', 'HOME': str(root)}
        command = [pi, '--mode', 'rpc', '--no-session', '--no-tools', '--no-mcp',
                   '--no-extensions', '--no-context-files', '--no-skills', '--no-prompt-templates',
                   '--no-approve', '--offline', '--provider', 'local-probe', '--model', model,
                   '--system-prompt', 'You extract JSON from supplied synthetic evidence. No tools. Return only JSON.']
        return run_child(command, root, env=env, timeout=timeout, prompt=prompt,
                         expected_artifact=expected_artifact)


def actual_pi_unavailable_probe(pi):
    return actual_pi_local_probe(pi, "http://127.0.0.1:9/v1", "missing-local-model")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pi', default=shutil.which('pi'))
    args = parser.parse_args()
    if not args.pi:
        parser.error('Pi executable unavailable')
    print(json.dumps(actual_pi_unavailable_probe(args.pi), indent=2))
