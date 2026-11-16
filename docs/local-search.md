# Local semantic search

Search combines keyword matches with up to 20 local E5 suggestions. Keyword matches appear first. Suggestions are ranked text similarities, not answers or guaranteed relevant matches. The selected multilingual E5-small model has demonstrated Ukrainian/English retrieval misses and has no calibrated relevance cutoff.

Search never uploads content. If the optional local component is missing, damaged or times out, keyword results remain available and Search explains the limitation. No automatic download or remote fallback runs during search.

Install the component explicitly from the repository, using Python 3.12 and a network connection for public packages and model weights only:

```sh
python3 scripts/install-local-search.py --component "$HOME/Library/Application Support/Stillmatter/Components/semantic-search"
```

The app reads this component from its own Application Support root. Test apps use their isolated support root. Installation downloads about 487 MB of model/tokenizer data, verifies pinned SHA-256 hashes and installs CPU ONNX Runtime, tokenizers and numpy into a dedicated virtual environment. Model source: intfloat/multilingual-e5-small, revision `ffdcc22a9a5c973ef0470385cef91e1ecb461d9f`, MIT license; provenance and earlier evaluation are in `docs/meeting_ai_handoff/local-model-candidates.md`. This optional component is not bundled with the app.

All passage tokens are processed in bounded windows; long queries exceeding 512 model tokens produce a visible semantic limitation rather than silent truncation. Search has a 120-second inference deadline. One inference process runs at a time; superseded queries waiting for capacity are discarded. Current retrieval recomputes vectors in a disposable child process per query, so large libraries can be slow. No vectors are persisted. Model failure does not modify canonical files.

The actual runtime lane was evaluated on macOS 15.8.3 x86_64 with Python 3.12. Other OS/hardware combinations, representative human-query relevance and very large library performance remain unverified; the app deployment target is unchanged.
