#!/usr/bin/env python3
"""Export transfer states from CI without media URLs, request headers or cookies."""
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / 'Library/Application Support/Riff/Downloads'
output = pathlib.Path(sys.argv[2])
try:
    jobs = json.loads((root / 'jobs.json').read_text())
    summary = [{key: job.get(key) for key in ('id', 'attempt', 'state', 'ext', 'isHLS', 'received', 'expected', 'hasResumeData', 'message')} for job in jobs]
    result = {'jobs': summary, 'receipts': len(list((root / 'Receipts').glob('*.json'))), 'staged_files': len(list((root / 'Staging').glob('*.download')))}
except (OSError, ValueError, TypeError) as error:
    result = {'unavailable': type(error).__name__}
output.write_text(json.dumps(result, indent=2))
