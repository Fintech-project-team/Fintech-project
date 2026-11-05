"""2026-11-04: 새 연간 자료의 원천·정답 분리와 난점 보존. 사용: unittest."""
from collections import Counter
import json
from pathlib import Path
import unittest
from testing.scenarios.gamma_fresh import build
from testing.scenarios.gamma_challenge import build as previous
from testing.analysis.gamma_evaluation import requests


class FreshYearTest(unittest.TestCase):
    """2026-11-04: 평가를 쉬운 사례나 중복 원천으로 바꾸지 못하게 검증한다."""

    @classmethod
    def setUpClass(cls):
        cls.source, cls.gold = build('holdout', 20261105)

    def test_new_ids_and_wording_keep_account_distribution(self):
        source = self.source
        old, _ = previous()
        self.assertFalse({row['transactionId'] for row in source['transactions']} &
                         {row['transactionId'] for row in old['transactions']})
        public = lambda rows: {(row['merchantName'], row['description']) for row in rows}
        self.assertFalse(public(source['transactions']) & public(old['transactions']))
        counts = Counter(row['accountId'] for row in source['transactions'] if row['accountId'])
        self.assertEqual([40, 40, 40, 40, 40, 800], sorted(counts.values()))
        self.assertEqual(3, len(source['accounts']) - len(counts))
        self.assertEqual(365, len({row['occurredAt'][:10] for row in source['transactions']}))
        self.assertEqual(1825, len(source['transactions']))

    def test_answer_key_and_difficulties_are_not_model_input(self):
        cases = requests(self.source, 20)
        labels = self.gold['transactions']
        self.assertEqual(1825, len(labels))
        self.assertGreater(sum(row['meaning'] is None for row in labels.values()), 400)
        kinds = Counter(row['recordKind'] for row in self.source['transactions'])
        self.assertEqual(52, kinds['card_cancellation'])
        self.assertEqual(52, kinds['card_refund'])
        serialized = json.dumps(cases, ensure_ascii=False)
        for private in ('expectedReview', 'labelOrigin', 'difficulty', 'basicType', 'expectedMeaning'):
            self.assertNotIn(private, serialized)
        targets = [item['targetTransactionId'] for case in cases for item in case['input']['items']
                   if item['targetTransactionId']]
        self.assertEqual(1825, len(set(targets)))
        self.assertEqual(1825, len(targets))
        self.assertLessEqual(max(len(case['input']['transactions']) for case in cases), 60)
        self.assertEqual(93, len(cases))

    def test_gold_is_observable_and_created_before_analysis(self):
        by_id = {row['transactionId']: row for row in self.source['transactions']}
        for key, answer in self.gold['transactions'].items():
            self.assertEqual('authored_before_provider', answer['labelOrigin'])
            if answer['meaning'] is None:
                self.assertIn(answer['expectedReview'],
                              ('ask_user_for_missing_information', 'taxonomy_review'))
            if answer['meaning'] == 'self_transfer':
                self.assertTrue(any(key in (row['fromId'], row['toId'])
                                    for row in self.source['transactionRelations']))
            if answer['meaning'] in ('cancellation', 'refund'):
                self.assertIn(by_id[key]['originalTransactionId'], by_id)

    def test_new_wording_and_balanced_tail_for_followup(self):
        """2026-11-04: 재평가에 이전 문장을 복사하지 않고 마지막 60초 대기 조건도 피한다."""
        source, gold = build('holdout', 20261106, variant=2)
        facts = lambda data: {(row['merchantName'], row['description'])
                              for row in data['transactions']}
        self.assertFalse(facts(source) & facts(self.source))
        cases = requests(source, 15)
        self.assertEqual(123, len(cases))
        self.assertTrue(all(10 <= len(case['input']['items']) <= 15 for case in cases))
        self.assertEqual(1825, len(gold['transactions']))
