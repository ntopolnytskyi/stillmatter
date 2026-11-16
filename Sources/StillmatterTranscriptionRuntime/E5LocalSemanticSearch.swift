import Foundation
import StillmatterCore

/// Offline E5 inference. Models and Python packages are installed explicitly; search
/// itself never downloads anything. Derived vectors live only in the child process.
public final class E5LocalSemanticSearch: LocalSemanticSearching {
    private let inferenceLock = NSLock()
    private let componentURL: URL
    private let timeout: TimeInterval

    public init(componentURL: URL, timeout: TimeInterval = 120) {
        self.componentURL = componentURL
        self.timeout = timeout
    }

    public func similarities(query: String, passages: [String]) throws -> [Double] {
        // Rapid queries share one memory-heavy model process. Superseded requests
        // waiting for that capacity never start another child.
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        try Task.checkCancellation()
        let python = componentURL.appendingPathComponent("runtime/bin/python3")
        let model = componentURL.appendingPathComponent("model.onnx")
        let tokenizer = componentURL.appendingPathComponent("tokenizer.json")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: tokenizer.path) else {
            throw failure("Install the offline E5 search component using docs/local-search.md, then retry Search.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Stillmatter-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.json")
        let output = temporary.appendingPathComponent("output.json")
        let script = temporary.appendingPathComponent("embed.py")
        try JSONSerialization.data(withJSONObject: ["query": query, "passages": passages]).write(to: input)
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let cancellation = JobExecutionCancellation()
        let deadline = DispatchWorkItem { _ = cancellation.cancelAndWait() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        do {
            // Minimal environment: no user Python hooks, hub access, credentials or providers.
            _ = try ProcessRunner().run(executable: python,
                arguments: ["-I", script.path, model.path, tokenizer.path, input.path, output.path],
                jobCancellation: cancellation,
                environment: ["PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "OMP_NUM_THREADS": "4"])
        } catch {
            throw failure(cancellation.isCancelled ? "Local semantic search timed out. Keyword search remains available."
                : "Offline E5 inference failed. Check the local search installation and retry.")
        }
        let scores = try JSONDecoder().decode([Double].self, from: Data(contentsOf: output))
        guard scores.count == passages.count, scores.allSatisfy({ $0.isFinite && (-1.001...1.001).contains($0) }) else {
            throw failure("Offline E5 returned invalid similarity scores.")
        }
        return scores
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Stillmatter.LocalSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // Pinned E5 tokenizer, complete token windows, masked mean pooling and L2 normalization.
    // Process at most eight 512-token windows at once, including for very long documents.
    public static let script = #"""
import hashlib, json, sys
import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

def verify(path, expected):
    digest = hashlib.sha256()
    with open(path, 'rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise ValueError('Local model/tokenizer checksum mismatch')

verify(sys.argv[1], 'ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665')
verify(sys.argv[2], '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39')
with open(sys.argv[3]) as source:
    request = json.load(source)
tokenizer = Tokenizer.from_file(sys.argv[2])
tokenizer.no_truncation()
tokenizer.no_padding()
options = ort.SessionOptions()
options.intra_op_num_threads = 4
options.inter_op_num_threads = 1
session = ort.InferenceSession(sys.argv[1], sess_options=options, providers=['CPUExecutionProvider'])

def embed(rows):
    length = max(map(len, rows))
    ids = np.full((len(rows), length), 1, dtype=np.int64)
    mask = np.zeros_like(ids)
    for i, row in enumerate(rows):
        ids[i, :len(row)] = row
        mask[i, :len(row)] = 1
    inputs = dict(input_ids=ids, attention_mask=mask, token_type_ids=np.zeros_like(ids))
    hidden = session.run(None, {key.name: inputs[key.name] for key in session.get_inputs()})[0]
    vectors = (hidden * mask[..., None]).sum(axis=1) / mask.sum(axis=1)[:, None]
    norms = np.linalg.norm(vectors, axis=1, keepdims=True)
    if not np.isfinite(vectors).all() or (norms == 0).any():
        raise ValueError('Invalid local embeddings')
    return vectors / norms

query = tokenizer.encode('query: ' + request['query']).ids
if len(query) > 512:
    raise ValueError('Query exceeds 512 tokens')
query_vector = embed([query])[0]
prefix = tokenizer.encode('passage: ', add_special_tokens=False).ids
scores = []
for passage in request['passages']:
    tokens = tokenizer.encode(passage, add_special_tokens=False).ids
    windows = ([0] + prefix + tokens[start:start+480] + [2] for start in range(0, max(1, len(tokens)), 480))
    best = -1.0
    batch = []
    for window in windows:
        batch.append(window)
        if len(batch) == 8:
            best = max(best, float((embed(batch) @ query_vector).max()))
            batch = []
    if batch:
        best = max(best, float((embed(batch) @ query_vector).max()))
    scores.append(best)
with open(sys.argv[4], 'w') as output:
    json.dump(scores, output, allow_nan=False)
"""#
}
