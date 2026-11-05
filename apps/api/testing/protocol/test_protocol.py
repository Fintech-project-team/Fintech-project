"""2026-11-04: 공개 규약 산출물/합성 지문/부정 타입을 무료로 검사한다. 사용: unittest."""
from copy import deepcopy
import json
from pathlib import Path
import unittest

from generate_vectors import vectors
from http_contract import document, validate
from identity_reference import canonical, hint
from mock_smoke import sample_requests
from http_examples import examples


class ProtocolTests(unittest.TestCase):
    """2026-11-04: 게시 파일이 생성 원본과 일치하고 임의 축약/타입 변환이 없는지 검사한다."""
    def test_frozen_vectors(self):
        """2026-11-04: 합성 대조 30개와 모든 기대값의 변경을 감지한다. 사용: unittest."""
        path=Path(__file__).parent/'fixtures/identity-vectors.json'
        self.assertEqual(json.loads(path.read_text(encoding='utf-8')),vectors())

    def test_schema(self):
        """2026-11-04: 작업 API 스키마도 원본과 동기화해야 한다. 사용: unittest."""
        path=Path(__file__).parents[2]/'contracts/analysis-http.schema.json'
        self.assertEqual(json.loads(path.read_text(encoding='utf-8')),document())

    def test_nullable_and_amount(self):
        """2026-11-04: null/누락/숫자 문자열/추가 필드를 동일 입력으로 취급하지 않는다. 사용: unittest."""
        source=vectors()['cases'][21]['input']
        validate('semanticInput',source)
        for change in ('missing','string_amount','unknown_field','wrong_version'):
            value=deepcopy(source)
            if change=='missing': del value['transactions'][0]['merchantName']
            if change=='string_amount': value['candidates'][0]['suggestedAmountKRW']='50000'
            if change=='unknown_field': value['extra']=True
            if change=='wrong_version': value['contractVersion']='PAYSE-ANALYSIS-2'
            with self.assertRaises(ValueError): validate('semanticInput',value)

    def test_hash_boundaries(self):
        """2026-11-04: 정규화 없는 문자열/집합 규약과 문맥 분리를 확인한다. 사용: unittest."""
        cases=vectors()['cases']
        self.assertNotEqual(hint(cases[5]['input']),hint(cases[6]['input']))
        self.assertNotEqual(hint(cases[8]['input']),hint(cases[9]['input']))
        self.assertNotEqual(hint(cases[21]['input']),hint(cases[25]['input']))
        self.assertEqual(canonical({'z':None,'a':0}),'{"a":0,"z":null}')

    def test_mock_requests(self):
        """2026-11-04: 합성 원천의 실제 식별자와 현재 계약에 맞는 예제만 준비한다. 사용: unittest."""
        path=Path(__file__).parents[2]/'fixtures/generated-v4/snapshots/demo-life.json'
        samples=sample_requests(json.loads(path.read_text(encoding='utf-8')))
        for key, schema in [('accept','acceptRequest'),('input','inputRequest'),('query','queryRequest')]:
            validate(schema,samples[key])

    def test_http_examples(self):
        """2026-11-04: 공개 봉투 14개가 서버 스키마와 일치하며 비밀 없는 예제로 유지되는지 검사한다."""
        path=Path(__file__).parent/'fixtures/http-examples.json'
        value=examples()
        self.assertEqual(14,len(value['examples']))
        self.assertEqual(value,json.loads(path.read_text(encoding='utf-8')))


if __name__=='__main__': unittest.main()
