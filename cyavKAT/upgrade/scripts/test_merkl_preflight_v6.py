#!/usr/bin/env python3
"""Network-free unit tests for Merkl fail-closed preflight. No compiler/deps required."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MOD=Path(__file__).with_name('merkl_preflight_v6.py')
spec=importlib.util.spec_from_file_location('merkl_preflight_v6', MOD)
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class M3PreflightTest(unittest.TestCase):
    def rewards(self, amount='0', claimed='0', pending='0'):
        return [{'chain':{'id':747474},'rewards':[
            {'token':{'address':'0x'+'1'*40,'symbol':'KAT'},
             'amount':amount,'claimed':claimed,'pending':pending}]}]

    def test_claimable_is_cumulative_minus_claimed(self):
        row=m.parse_rewards(self.rewards('13','12','20'))[0]
        self.assertEqual(row['claimableRaw'],'1')
        self.assertEqual(row['pendingRaw'],'20')

    def test_wrong_chain_and_malformed_fail_closed(self):
        with self.assertRaises(ValueError):m.parse_rewards({})
        with self.assertRaises(ValueError):m.parse_rewards([{'chain':{'id':1},'rewards':[]}])
        with self.assertRaises(ValueError):m.parse_rewards(self.rewards('4','8'))
        with self.assertRaises(ValueError):m.parse_rewards([{'chain':{'id':747474}}])

    def test_positive_claimable_cannot_create_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            outfile=Path(d)/'receipt.json'
            def fake_json(url,payload=None):
                if payload:return {'result':{'hash':'0x'+'a'*64}}
                if m.VAULT.lower() in url:return self.rewards('2','1')
                return self.rewards()
            with patch.object(m,'get_json',side_effect=fake_json),patch.object(m,'rpc',side_effect=[hex(m.CHAIN),'0x100']):
                with self.assertRaisesRegex(RuntimeError,'CLAIM REWARDS FIRST'):
                    m.run(['--rpc-url','https://fake.invalid','--out',str(outfile)])
            self.assertFalse(outfile.exists())

    def test_zero_claimable_writes_anchored_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            outfile=Path(d)/'receipt.json'
            def fake_json(url,payload=None):
                if payload:return {'result':{'hash':'0x'+'b'*64}}
                return self.rewards('22','22')
            with patch.object(m,'get_json',side_effect=fake_json),patch.object(m,'rpc',side_effect=[hex(m.CHAIN),'0x100']):
                self.assertEqual(m.run(['--rpc-url','https://fake.invalid','--out',str(outfile)]),0)
            receipt=json.loads(outfile.read_text())
            self.assertEqual(receipt['claimableTotalRawVault'],0)
            self.assertEqual(receipt['checkedBlockNumber'],255)
            self.assertEqual(receipt['checkedBlockHash'],'0x'+'b'*64)

if __name__=='__main__': unittest.main()
