"""2026-11-04: Java·Dart 공통 합성 입력 30개와 독립 계산한 기대 지문을 만든다. 사용: CLI."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
import uuid

DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(DIRECTORY.parent / 'analysis'))
from contract import validate_input
from identity_reference import canonical, identities


def uid(label):
    """2026-11-04: 실제 사용자/거래를 참조하지 않는 고정 합성 ID다. 사용: transaction."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'payse-public-protocol/' + label))


def transaction(label, **changes):
    """2026-11-04: 공개 최소 원천 필드만 준비한다. 사용: base, vectors."""
    return dict(transactionId=uid(label), recordKind='account_entry', direction='in',
        status='posted', reflectionReason='reflected', merchantName='합성 거래처',
        description='확인용 입금', originalTransactionId=None, **{}) | changes


def base(rows=None, recurring=False):
    """2026-11-04: 합성 원천의 의미 입력을 만들며 금액 계산/DB 연결을 하지 않는다. 사용: vectors."""
    rows = rows or [transaction('a')]
    context = dict(schemaVersion='PAYSE-API-0.6-4', dataVersion='1',
        sourceVersion='public-protocol-source-1', ruleVersion='PAYSE-CALC-1',
        asOf='2026-11-04T12:00:00+09:00', inputRevision=0,
        localSessionEpoch=1, selectedAccountIds=[])
    items = [dict(itemKey=f'item-{index}', targetTransactionId=row['transactionId'],
        candidateKey=None, evidenceTransactionIds=[row['transactionId']])
        for index, row in enumerate(rows)]
    candidates = []
    if recurring:
        ids = [row['transactionId'] for row in rows]
        items = [dict(itemKey='recurring-item', targetTransactionId=None,
            candidateKey='candidate-1', evidenceTransactionIds=ids)]
        candidates = [dict(candidateKey='candidate-1', ruleVersion=context['ruleVersion'],
            sourceVersion=context['sourceVersion'], evidenceTransactionIds=ids,
            normalizedName='합성 통신요금', suggestedAmountKRW=50000, suggestedDay=20,
            features=dict(occurrenceCount=3, observedMonths=['2026-08','2026-09','2026-10'],
                          dayWithinRule=True, amountWithinRule=True, hasUnresolvedReversal=False))]
    return dict(contractVersion='PAYSE-ANALYSIS-1',
        semanticTaskKind='recurringMeaning' if recurring else 'transactionMeaning',
        context=context, items=items, transactions=rows, relations=[],
        unavailableReferences=[], currentClassifications=[], candidates=candidates)


def vectors():
    """2026-11-04: 변경/동등 사례를 명시하고 분석 정답과 무관한 지문 기대값을 동결한다. 사용: main."""
    cases = []

    def add(name, payload, same_as=None):
        validate_input(payload)
        case = dict(id=f'P{len(cases)+1:02d}', name=name, input=deepcopy(payload),
                    expected=identities(payload))
        case['expected']['canonicalInput'] = canonical(payload)
        if same_as:
            case['sameHintAs'] = same_as
        cases.append(case)

    original = base()
    add('한글 기본 입력', original)
    add('객체 필드 역순', dict(reversed(list(original.items()))), 'P01')
    value = deepcopy(original); value['items'][0]['itemKey']='화면-새-항목'
    add('임시 itemKey 변경', value, 'P01')
    value = deepcopy(original); value['context'].update(dataVersion='9223372036854775807',
        sourceVersion='source-next', asOf='2026-11-05T03:00:00Z', inputRevision=7, localSessionEpoch=8)
    add('문맥만 변경', value, 'P01')
    for name, description in [('원문 공백 보존',' 확인용 입금 '), ('빈 문자열',''),
        ('null',None), ('따옴표·역슬래시·개행','"합성"\\영수증\n둘째 줄\t탭'),
        ('한글 완성형','가'), ('한글 분해형','가'),
        ('보조 평면 문자·줄 구분 문자','확인 😀\u2028다음'), ('원문 대소문자','PaySe')]:
        value=deepcopy(original); value['transactions'][0]['description']=description
        add(name,value)
    multi=base([transaction('a'),transaction('b')])
    add('두 독립 항목', multi)
    value=deepcopy(multi)
    for field in ('items','transactions'): value[field].reverse()
    add('항목·거래 순서 반전',value,'P13')
    value=deepcopy(multi); value['currentClassifications']=[dict(transactionId=uid('a'),value='income')]
    add('확인된 기존 분류',value)
    transfer=base([transaction('out',direction='out'),transaction('in')])
    transfer['relations']=[dict(kind='internal_transfer',fromId=uid('out'),toId=uid('in'))]
    add('본인 이체 관계의 양끝 확장',transfer)
    value=deepcopy(transfer)
    for field in ('items','transactions','relations'): value[field].reverse()
    add('이체 원천 순서 반전',value,'P16')
    purchase=transaction('purchase',recordKind='card_purchase',direction='out',status='approved',
                         reflectionReason='not_applicable')
    for name, kind, status in [('원구매를 포함한 환불','card_refund','posted'),
                                ('원구매를 포함한 취소','card_cancellation','cancelled')]:
        add(name,base([purchase,transaction('reversal',recordKind=kind,status=status,
            reflectionReason='not_applicable',originalTransactionId=uid('purchase'))]))
    value=base([transaction('refund',recordKind='card_refund',
        reflectionReason='not_applicable',originalTransactionId=uid('missing'))])
    value['unavailableReferences']=[dict(transactionId=uid('missing'),reason='outside_retention')]
    add('미확보 원구매와 보존기간 사유',value)
    value=deepcopy(value);value['unavailableReferences'][0]['reason']='not_provided'
    add('미확보 사유 변경',value)
    recurring=base([transaction('r'+str(n),direction='out') for n in range(3)],True)
    add('최근 세 달 반복 입력',recurring)
    value=deepcopy(recurring);value['items'][0].update(itemKey='new-item',candidateKey='new-key')
    value['candidates'][0]['candidateKey']='new-key'
    add('반복 임시 식별자 변경',value,'P22')
    value=deepcopy(recurring);value['transactions'].reverse()
    value['items'][0]['evidenceTransactionIds'].reverse()
    value['candidates'][0]['evidenceTransactionIds'].reverse()
    value['candidates'][0]['features']['observedMonths'].reverse()
    add('반복 근거·관찰 월 순서 반전',value,'P22')
    for name,key,new in [('정규화명 변경','normalizedName','합성 보험료'),
                         ('로컬 마지막 확인 금액 변경','suggestedAmountKRW',9000000000000),
                         ('로컬 예정일 미확인','suggestedDay',None)]:
        value=deepcopy(recurring);value['candidates'][0][key]=new;add(name,value)
    value=deepcopy(recurring);value['candidates'][0]['features']['occurrenceCount']=4
    add('로컬 횟수 변경',value)
    value=deepcopy(recurring)
    value['candidates'][0]['features']['observedMonths']=['2026-07','2026-08','2026-09']
    add('관찰 월 집합 변경',value)
    value=deepcopy(recurring);value['context']['sourceVersion']='new-source'
    value['candidates'][0]['sourceVersion']='new-source'
    add('반복 원천 버전 메타만 변경',value,'P22')
    assert len(cases)==30
    for case in cases:
        if 'sameHintAs' in case:
            previous=next(row for row in cases if row['id']==case['sameHintAs'])
            assert previous['expected']['inputHashHint']==case['expected']['inputHashHint']
    return dict(format='PAYSE-IDENTITY-VECTORS-1', identityProfile='PAYSE-IDENTITY-1',
                contractVersion='PAYSE-ANALYSIS-1', cases=cases)


def main():
    """2026-11-04: 기본은 변경 없는 검사이며 --write 때만 공개 합성 파일을 갱신한다. 사용: CLI."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true')
    args=parser.parse_args();path=DIRECTORY/'fixtures/identity-vectors.json';value=vectors()
    if args.write:
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    elif json.loads(path.read_text(encoding='utf-8'))!=value:
        raise ValueError('Public identity vectors are stale')
    print('PASS: 30 public identity vectors')


if __name__=='__main__': main()
