#!/usr/bin/env python3
"""M3 claimability preflight for the cyavKAT RCM fuse removal.

Standard library only. Fails closed on HTTP errors, unknown Merkl response structures,
negative amounts, wrong chain, and immediately claimable rewards. Run before P2_04,
not as an unattended cleanup task. Writes a block-bound receipt for the Forge script.
"""
import argparse
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

CHAIN = 747474
VAULT = '0xEd83daf48429cfb2C650Fd721b9241e180fd4548'
RCM = '0xA77470B748A8Fb50056Ca3c07375dC76Aa3A72Cb'
API = 'https://api.merkl.xyz/v4/users/{}/rewards?chainId=747474'


def get_json(url, payload=None):
    req = urllib.request.Request(url, headers={'User-Agent': 'cyavKAT-merkl-preflight-v6/1.0',
                                              'Content-Type': 'application/json'},
                                 data=None if payload is None else json.dumps(payload).encode('utf-8'))
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def rpc(url, method, args):
    data = get_json(url, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': args})
    if not isinstance(data, dict) or data.get('error') or not isinstance(data.get('result'), str):
        raise RuntimeError(f'{method} returned an invalid RPC response: {data}')
    return data['result']


def parse_rewards(data):
    """Accepted Merkl v4 shape is [{chain:{id},rewards:[...]}]; never treat unknown data as empty."""
    if not isinstance(data, list):
        raise ValueError('unrecognized Merkl response: expected array of chain reward objects')
    rows = []
    for group in data:
        if not isinstance(group, dict) or not isinstance(group.get('rewards'), list):
            raise ValueError('unrecognized Merkl response group: expected rewards array')
        chain = group.get('chain')
        if not isinstance(chain, dict) or int(chain.get('id', -1)) != CHAIN:
            raise ValueError('unexpected chain in Merkl response')
        for reward in group['rewards']:
            if not isinstance(reward, dict) or not isinstance(reward.get('token'), dict):
                raise ValueError('unrecognized token reward record')
            token = reward['token'].get('address')
            if not isinstance(token, str) or not token.startswith('0x') or len(token) != 42:
                raise ValueError('missing reward token address')
            amount = int(reward['amount'])
            claimed = int(reward['claimed'])
            pending = int(reward.get('pending', '0'))
            if claimed < 0 or amount < 0 or pending < 0 or claimed > amount:
                raise ValueError('inconsistent Merkl amounts')
            rows.append({'token': token, 'symbol': str(reward['token'].get('symbol', '')),
                         'claimableRaw': str(amount - claimed), 'pendingRaw': str(pending)})
    return rows


def run(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rpc-url', default=os.getenv('KATANA_RPC_URL'), required=False)
    parser.add_argument('--out', default='deployments/merkl-preflight-v6.json')
    args = parser.parse_args(argv)
    if not args.rpc_url:
        parser.error('provide --rpc-url or KATANA_RPC_URL')
    if int(rpc(args.rpc_url, 'eth_chainId', []), 16) != CHAIN:
        raise RuntimeError('wrong RPC chain; expected Katana 747474')
    latest = rpc(args.rpc_url, 'eth_blockNumber', [])
    block_no = int(latest, 16)
    # Anchor to previous *confirmed* block, not the head being written. The verifier
    # checks the canonical block hash in the transaction's block (within 200 blocks).
    checked = block_no - 1
    block = get_json(args.rpc_url, {'jsonrpc': '2.0', 'id': 1,
                                    'method': 'eth_getBlockByNumber',
                                    'params': [hex(checked), False]})
    info = block.get('result') if isinstance(block, dict) else None
    if not isinstance(info, dict) or not isinstance(info.get('hash'), str) or len(info['hash']) != 66:
        raise RuntimeError('cannot anchor to confirmed Katana block')
    data_v = parse_rewards(get_json(API.format(VAULT.lower())))
    data_r = parse_rewards(get_json(API.format(RCM.lower())))
    claimable_v = sum(int(i['claimableRaw']) for i in data_v)
    claimable_r = sum(int(i['claimableRaw']) for i in data_r)
    pending = sum(int(i['pendingRaw']) for i in data_v + data_r)
    receipt = {'schema': 'cyavKAT-merkl-M3-v6', 'chainId': CHAIN,
               'vault': VAULT, 'rewardsManager': RCM,
               'checkedBlockNumber': checked, 'checkedBlockHash': info['hash'],
               'claimableTotalRawVault': claimable_v,
               'claimableTotalRawRewardsManager': claimable_r,
               'unclaimablePendingTotalRaw': pending,
               'vaultRewards': data_v, 'rewardsManagerRewards': data_r,
               'sources': [API.format(VAULT.lower()), API.format(RCM.lower())]}
    target = Path(args.out)
    if claimable_v or claimable_r:
        print(json.dumps(receipt, indent=2))
        raise RuntimeError('CLAIM REWARDS FIRST: nonzero claimable Merkl rewards; no migration receipt written')
    target.parent.mkdir(parents=True, exist_ok=True)
    # Atomic write so interruption never leaves a truncated receipt.
    fd, temp = tempfile.mkstemp(dir=str(target.parent), prefix='.merkl-preflight-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(receipt, output, indent=2)
            output.write('\n')
        os.replace(temp, target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    print(f'M3 PASS: {target} (Katana block {checked}, zero claimable rewards for both wallets)')
    if pending:
        print('NOTICE: Merkl also reports unclaimable pending rewards. Review before running M4.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(run())
    except (ValueError, RuntimeError, urllib.error.URLError, OSError) as e:
        print(f'M3 BLOCKED: {e}', file=sys.stderr)
        sys.exit(1)
