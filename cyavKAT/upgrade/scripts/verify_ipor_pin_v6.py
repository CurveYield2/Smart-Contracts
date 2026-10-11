#!/usr/bin/env python3
"""Verify shipped IPOR contracts are byte-exact exports from the pinned upstream commit.

Runs without modifying or compiling the bundled contract tree. Supply a pre-existing
upstream IPOR git checkout; fetch/compile only in a remote GitHub environment if needed.
Example: python scripts/verify_ipor_pin_v6.py --upstream /work/ipor-fusion
"""
import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

PIN = 'a1f79d6c3d0d426ace4df55ed0fb8ea340580739'

def run(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--upstream', required=True, type=Path)
    ap.add_argument('--bundled', default=Path(__file__).resolve().parents[2] / 'ipor-fusion' / 'contracts', type=Path)
    args = ap.parse_args(argv)
    rev = subprocess.run(['git', '-C', str(args.upstream), 'rev-parse', PIN+'^{commit}'],
                         check=True, capture_output=True, text=True).stdout.strip()
    if rev != PIN:
        raise ValueError(f'upstream revision mismatch: {rev}')
    src_files = sorted(args.bundled.rglob('*.sol'))
    if len(src_files) != 90:
        raise ValueError(f'expected 90 pinned Solidity files, got {len(src_files)}')
    hashes = {}
    for path in src_files:
        rel = path.relative_to(args.bundled)
        original = subprocess.run(['git', '-C', str(args.upstream), 'show',
                                   f'{PIN}:contracts/{rel.as_posix()}'],
                                  check=True, capture_output=True).stdout
        content = path.read_bytes()
        if original != content:
            raise ValueError(f'IPOR pin mismatch: {rel}')
        hashes[str(rel)] = hashlib.sha256(content).hexdigest()
    print('PASS: all 90 bundled IPOR Solidity files match', PIN, 'byte for byte')
    print('Pinned source tree SHA256:', hashlib.sha256(''.join(f'{k}:{v}\n' for k,v in hashes.items()).encode()).hexdigest())
    print('NOTE: live runtime bytecode still requires the separate Foundry/cast equivalence test in docs/PROVENANCE_VERIFICATION_v6.md')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(run())
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('FAIL:', exc, file=sys.stderr)
        sys.exit(1)
