#!/usr/bin/env python3
"""Explicit installation only: download public E5 weights, never workspace content."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--component', type=Path, required=True)
parser.add_argument('--python', default='/usr/local/bin/python3.12')
args = parser.parse_args()
args.component.mkdir(parents=True, exist_ok=True)
runtime = args.component / 'runtime'
subprocess.run([args.python, '-m', 'venv', str(runtime)], check=True)
subprocess.run([str(runtime / 'bin/python3'), '-m', 'pip', 'install', '--disable-pip-version-check',
                'onnxruntime==1.23.2', 'tokenizers==0.21.4', 'numpy==2.2.6'], check=True)
base = 'https://huggingface.co/intfloat/multilingual-e5-small/resolve/ffdcc22a9a5c973ef0470385cef91e1ecb461d9f/onnx/'
for name, digest in [('model.onnx', 'ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665'),
                     ('tokenizer.json', '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39')]:
    target = args.component / name
    staging = target.with_suffix('.download')
    try:
        urllib.request.urlretrieve(base + name, staging)
        if hashlib.file_digest(staging.open('rb'), 'sha256').hexdigest() != digest:
            raise ValueError('Downloaded model checksum mismatch: ' + name)
        staging.replace(target)
    finally:
        staging.unlink(missing_ok=True)
print('Offline E5 search component installed at', args.component)
