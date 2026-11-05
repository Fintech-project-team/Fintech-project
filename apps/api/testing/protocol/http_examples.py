"""2026-11-04: 인증 자료 없는 공개 합성 HTTP 예제를 만든다. 사용: CLI, protocol unit tests."""
from copy import deepcopy
import argparse
import json
from pathlib import Path
from generate_vectors import vectors, uid
from http_contract import validate


def examples():
    """2026-11-04: 정상/유보/실패 봉투와 요청을 분리해 현 스키마에 대조한다. 실행 원천은 아니다."""
    payload=vectors()['cases'][21]['input']
    context=payload['context']
    descriptor=payload['items'][0]
    job=uid('public-job');result_id=uid('public-result');item_id=uid('public-item')
    hint=vectors()['cases'][21]['expected']['inputHashHint']
    result=[]

    def add(name, schema, value):
        """2026-11-04: 실제 비밀/세션 없이 명명한 계약 예제를 동결한다. 사용: examples."""
        validate(schema,value)
        result.append(dict(name=name,schema=schema,value=value))

    add('accept','acceptRequest',dict(context=context,triggerKind='B',
        semanticTaskKind='recurringMeaning',items=[dict(itemKey=descriptor['itemKey'],
        evidenceTransactionIds=descriptor['evidenceTransactionIds'],
        candidateIds=[descriptor['candidateKey']])],inputHashHint=hint,reasonCodes=[],
        idempotencyKey='public-example-accept'))
    # 문법 설명용 합성 허가값이며 어떤 실행 중인 서버에도 발급되지 않았다.
    permit='sha256:'+'0'*64
    add('input','inputRequest',dict(context=context,input=payload,permit=permit,
                                  idempotencyKey='public-example-input'))
    add('retry_after_acknowledgement','retryRequest',dict(context=context,input=payload,
        acknowledgeDuplicateRisk=True,idempotencyKey='public-example-retry'))
    add('query','queryRequest',dict(context=context,semanticTaskKind='recurringMeaning',input=payload))
    for state,action in [('queued','wait'),('awaitingInput','submitInput'),('running','wait'),
                          ('succeeded','readResult'),('failed','retry'),('outcomeUnknown','retry')]:
        value=dict(contractVersion='PAYSE-ANALYSIS-1',jobId=job,state=state,
                   action=action,resultAvailability='unchecked')
        if state=='awaitingInput':
            value.update(permit=permit,permitExpiresAt='2026-11-04T00:01:00Z')
        if state=='succeeded': value['resultId']=result_id
        if state in ('failed','outcomeUnknown'):
            value['review']=dict(reason=state,requiresUserInput=True,itemsAvailable=True,
                retryRequiresAcknowledgement=state=='outcomeUnknown',
                items=[dict(itemKey=descriptor['itemKey'])])
        add(state,'jobResponse',value)
    for known in (True,False):
        interpretation=dict(itemKey=descriptor['itemKey'],candidateKey=descriptor['candidateKey'],
            name='통신 요금' if known else None,
            evidenceTransactionIds=descriptor['evidenceTransactionIds'],
            reason='월별 통신료 근거를 확인했습니다.' if known else '출금 목적을 사용자에게 확인해 주세요.',
            meaning=dict(status='candidate' if known else 'unknown',value='telecom' if known else None,
                         reasonCode='supported' if known else 'insufficient_evidence'))
        value=dict(contractVersion='PAYSE-ANALYSIS-1',resultAvailability='available',
            context=context,resultId=result_id,result=dict(meaningPolicyVersion='PAYSE-MEANING-1',
            items=[dict(itemId=item_id,interpretation=interpretation,retentionReason='합성 예제',
                active=True,important=False,isReference=True,referencePolicy='optional',
                storedAt='2026-11-04T00:00:00Z',normalExpiresAt='2027-02-04T00:00:00Z')],
            itemAvailability=[dict(itemKey=descriptor['itemKey'],state='available',itemId=item_id)]))
        add('available_candidate' if known else 'available_unknown','queryResponse',value)
    add('missing','queryResponse',dict(contractVersion='PAYSE-ANALYSIS-1',
        resultAvailability='missing',context=deepcopy(context)))
    add('stale_data','errorResponse',dict(error=dict(code='STALE_DATA',message='최신 자료로 다시 확인해 주세요.',
        requestId=uid('public-request'),details=[])))
    return dict(format='PAYSE-HTTP-EXAMPLES-1',synthetic=True,executableAgainstMockDatabase=False,
                examples=result)


def main():
    """2026-11-04: 명시 --write만 공개 예제를 갱신하고 기본 실행은 동일성을 검사한다. 사용: CLI."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write',action='store_true')
    args=parser.parse_args();path=Path(__file__).parent/'fixtures/http-examples.json';value=examples()
    if args.write:
        path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    elif json.loads(path.read_text(encoding='utf-8'))!=value:
        raise ValueError('Public HTTP examples are stale')
    print('PASS: 14 public HTTP examples')


if __name__=='__main__': main()
