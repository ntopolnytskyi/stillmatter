"""Non-shipped offline E5 inference on a labelled synthetic retrieval smoke set."""
import argparse
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import resource
import time

MODEL_HASH = 'ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665'


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def score_rankings(passages, queries, scores):
    ids = [p['id'] for p in passages]
    if len(ids) != len(set(ids)) or not ids:
        raise ValueError('Passage IDs must be unique and nonempty')
    if len(queries) != len(scores):
        raise ValueError('One score row required per query')
    results = []
    for query, row in zip(queries, scores):
        if len(row) != len(ids) or not all(math.isfinite(s) for s in row):
            raise ValueError('Invalid score row')
        relevant = query['relevant']
        if relevant is not None and relevant not in ids:
            raise ValueError('Unknown relevant passage')
        ranking = sorted(range(len(ids)), key=lambda i: (-row[i], ids[i]))
        rank = next((i + 1 for i, index in enumerate(ranking) if ids[index] == relevant), None)
        results.append({'query': query['text'], 'relevant': relevant, 'rank': rank,
                        'ranking': [{'id': ids[i], 'cosine': float(row[i])} for i in ranking]})
    ranks = [r['rank'] for r in results if r['relevant'] is not None]
    return {'answerableQueries': len(ranks), 'unanswerableQueries': len(results) - len(ranks),
            'recallAt1': sum(r <= 1 for r in ranks) / len(ranks) if ranks else None,
            'recallAt3': sum(r <= 3 for r in ranks) / len(ranks) if ranks else None,
            'meanReciprocalRank': sum(1 / r for r in ranks) / len(ranks) if ranks else None,
            'results': results,
            'abstention': 'Not calibrated; a nearest result for the unanswerable query is not evidence.'}


def evaluate(model, tokenizer_path, fixtures):
    # All paths are explicit local files. No hub or provider API is used.
    import numpy as np
    import onnxruntime as ort
    from tokenizers import Tokenizer
    if sha256(model) != MODEL_HASH:
        raise ValueError('Model hash differs from pinned publisher artifact')
    dataset = json.loads(Path(fixtures).read_text())
    texts = ['passage: ' + p['text'] for p in dataset['passages']]
    texts += ['query: ' + q['text'] for q in dataset['queries']]
    tokenizer = Tokenizer.from_file(str(tokenizer_path))
    tokenizer.no_truncation()
    tokenizer.enable_padding(pad_id=1, pad_token='<pad>')
    encoded = tokenizer.encode_batch(texts)
    if max(len(e.ids) for e in encoded) > 512:
        raise ValueError('Fixture exceeds 512 tokens; do not silently truncate')
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.inter_op_num_threads = 1
    start = time.monotonic()
    session = ort.InferenceSession(str(model), sess_options=options, providers=['CPUExecutionProvider'])
    loaded = time.monotonic() - start
    inputs = {'input_ids': np.array([e.ids for e in encoded], dtype=np.int64),
              'attention_mask': np.array([e.attention_mask for e in encoded], dtype=np.int64),
              'token_type_ids': np.array([e.type_ids for e in encoded], dtype=np.int64)}
    start = time.monotonic()
    cpu_start = time.process_time()
    hidden = session.run(None, {i.name: inputs[i.name] for i in session.get_inputs()})[0]
    mask = inputs['attention_mask'][..., None]
    vectors = (hidden * mask).sum(axis=1) / mask.sum(axis=1)
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    if not np.isfinite(vectors).all() or (norms == 0).any():
        raise ValueError('Invalid model vectors')
    vectors /= norms
    count = len(dataset['passages'])
    scores = vectors[count:] @ vectors[:count].T
    elapsed = time.monotonic() - start
    cpu_elapsed = time.process_time() - cpu_start
    report = score_rankings(dataset['passages'], dataset['queries'], scores.tolist())
    report.update({'kind': 'actual-local-inference-synthetic-smoke-only',
                   'model': 'intfloat/multilingual-e5-small FP32 ONNX',
                   'modelRevision': 'ffdcc22a9a5c973ef0470385cef91e1ecb461d9f',
                   'hashes': {name: sha256(path) for name, path in
                              [('model', model), ('tokenizer', tokenizer_path), ('fixtures', fixtures)]},
                   'runtime': {name: importlib.metadata.version(name) for name in ['onnxruntime', 'tokenizers', 'numpy']},
                   'environment': {'platform': platform.platform(), 'python': platform.python_version()},
                   'settings': {'provider': 'CPUExecutionProvider', 'threads': 4, 'dimensions': int(vectors.shape[1]),
                                'pooling': 'attention-masked mean then L2', 'maxFixtureTokens': max(len(e.ids) for e in encoded)},
                   'modelLoadSeconds': loaded, 'inferenceSeconds': elapsed,
                   'processCPUSeconds': cpu_elapsed,
                   'peakRSSBytes': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if platform.system() == 'Darwin' else 1024),
                   'limitations': 'No archive/edit/purge/delete product integration tested. No long-document chunker or relevance threshold validated. No vectors retained.'})
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--tokenizer', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, default=Path(__file__).with_name('retrieval-fixtures.json'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = evaluate(args.model, args.tokenizer, args.fixtures)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['recallAt1', 'recallAt3', 'meanReciprocalRank', 'inferenceSeconds', 'peakRSSBytes']}))
