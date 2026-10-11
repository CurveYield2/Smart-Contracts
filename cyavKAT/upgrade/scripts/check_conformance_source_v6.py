#!/usr/bin/env python3
"""Offline, read-only V6 fuse scope/ABI/invariant smoke checks; NOT a compiler or an audit.

No dependency installation, compilation, or network requests. Expected to run before
(remote GitHub) Forge build and Katana fork tests, not in place of them.
"""
from pathlib import Path
import re
import sys
ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT/'upgrade/src'

FUSES = {
  'generic/CurveYieldBundleGuardFuse.sol': ('enter','exit','enterTransient','exitTransient'),
  'generic/CurveYieldErc20TransferFuse.sol': ('enter','exit','enterTransient','exitTransient'),
  'generic/CurveYieldBurnHeldSharesFuse.sol': ('enter','exit','enterTransient','exitTransient'),
  'withdraw/CurveYieldRequestFeeSharesFuse.sol': ('enter','exit','enterTransient','exitTransient'),
  'generic/CurveYieldErc1271InstallFuse.sol': ('enter','exit','enterTransient','exitTransient'),
  'generic/CurveYieldErc1271ConfigFuse.sol': ('enter','exit','enterTransient','exitTransient'),
}

def require(cond, message):
    if not cond:
        raise AssertionError(message)

def run():
    for rel, functions in FUSES.items():
        code = (SRC/rel).read_text()
        require('is IFuseCommon' in code, f'{rel}: not IFuseCommon')
        require('VERSION = address(this)' in code, f'{rel}: version does not identify code instance')
        require('immutable override MARKET_ID' in code, f'{rel}: MARKET_ID not immutable/IFuseCommon')
        require('marketId_ == 0' in code, f'{rel}: zero market accepted')
        for fn in functions:
            require(re.search(r'\bfunction\s+'+fn+r'\s*\(', code) is not None, f'{rel}: missing {fn}')
        for forbidden in ('owner()', 'executeInternal('):
            require(forbidden not in code, f'{rel}: contains forbidden selector {forbidden}')
    balance=(SRC/'generic/CurveYieldRateAwareBalancerBalanceFuse.sol').read_text()
    require('marketId_ == 0' in balance, 'balance fuse missing zero market rejection')
    require('VERSION = address(this)' in balance, 'balance fuse lacks version')
    conf=(ROOT/'upgrade/script/P2_04_RemoveV1Fuses.s.sol').read_text()
    require('_requireMerklM3()' in conf and 'blockhash(checkedBlock)' in conf and 'claimableTotalRawVault' in conf, 'M3 missing or unsafe')
    setup=(ROOT/'upgrade/test/helpers/Phase2ForkBase.sol').read_text()
    require('K1_QuestSigning signing' in setup and 'QUEST_DETACH_INSTALL' in setup, 'fork suite lacks mandatory Quest V2')
    for banned in ('CurveYieldSushiLpController','CurveYieldUsdcSupplyLoopFuse','CurveYieldVkatStrategyFuse'):
        # No such names in live upgrade/source trees; historical docs and deployed/ are deliberately retained.
        require(not list(SRC.rglob('*'+banned+'*.sol')), f'retired fuse present: {banned}')
    source=list((ROOT/'ipor-fusion/contracts').rglob('*.sol'))
    require(len(source)==90, f'official IPOR set changed (got {len(source)})')
    docs=list((ROOT/'docs/fuses').glob('*_v6.md'))
    require(len(docs)==6, f'six custom family READMEs expected; got {len(docs)}')
    print('PASS: V6 static fuse signatures, zero-market guards, M3 gate, mandatory Quest, IPOR file count, docs')
    print('CAUTION: compilation, selector-generation, source provenance, runtime economics and fork tests NOT covered')

if __name__=='__main__':
    try:
        run()
    except Exception as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
