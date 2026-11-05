"""2026-11-04: 실제 인증 HTTP로 모의 공급자 접수/저장/재시도/복원을 확인한다. 사용: mock_server."""
from copy import deepcopy
import json
import time
import urllib.error
import urllib.request
import uuid

from http_contract import validate
from identity_reference import hint


def sample_requests(source):
    """2026-11-04: 합성 원천에 있는 통신료 세 건을 분석 요청으로 연결한다. 사용: mock_server."""
    expected={'fixture/alpha/transaction/account-expense/0/'+month
              for month in ('2026-08','2026-09','2026-10')}
    rows=[row for row in source['transactions'] if row['sourceRef'] in expected]
    if (len(rows)!=3 or {row['sourceRef'] for row in rows}!=expected
        or len({row['accountId'] for row in rows})!=1
        or any(row['userId']!=source['userId'] or row['recordKind']!='account_entry'
               or row['direction']!='out' or row['status']!='posted' for row in rows)):
        raise ValueError('Expected three synthetic monthly telecom rows')
    rows.sort(key=lambda row:row['withdrawalDate'])
    fields=['transactionId','recordKind','direction','status','reflectionReason','merchantName',
            'description','originalTransactionId']
    context={field:source[field] for field in ('dataVersion','sourceVersion','ruleVersion','asOf')}
    context.update(schemaVersion='PAYSE-API-0.6-4',inputRevision=0,localSessionEpoch=1,
        selectedAccountIds=[row['accountId'] for row in source['accounts'] if row['included']])
    refs=[row['transactionId'] for row in rows]
    candidate=dict(candidateKey='mock-telecom',ruleVersion=context['ruleVersion'],
        sourceVersion=context['sourceVersion'],evidenceTransactionIds=refs,
        normalizedName='통신 요금',suggestedAmountKRW=50000,suggestedDay=15,
        features=dict(occurrenceCount=3,observedMonths=['2026-08','2026-09','2026-10'],
            dayWithinRule=True,amountWithinRule=True,hasUnresolvedReversal=False))
    payload=dict(contractVersion='PAYSE-ANALYSIS-1',semanticTaskKind='recurringMeaning',
        context=context,items=[dict(itemKey='monthly-telecom',targetTransactionId=None,
            candidateKey=candidate['candidateKey'],evidenceTransactionIds=refs)],
        transactions=[{field:row[field] for field in fields} for row in rows],relations=[],
        unavailableReferences=[],currentClassifications=[dict(transactionId=row['transactionId'],
            value=row['payseTransactionType']) for row in rows],candidates=[candidate])
    acceptance=dict(context=context,triggerKind='A',semanticTaskKind='recurringMeaning',
        items=[dict(itemKey='monthly-telecom',evidenceTransactionIds=refs,
                    candidateIds=[candidate['candidateKey']])],inputHashHint=hint(payload),
        reasonCodes=[],idempotencyKey='mock-accept-'+uuid.uuid4().hex)
    query=dict(context=context,semanticTaskKind='recurringMeaning',input=payload)
    for name,value in [('acceptRequest',acceptance),('queryRequest',query)]: validate(name,value)
    return dict(accept=acceptance,input=dict(context=context,input=payload,
        idempotencyKey='mock-input-'+uuid.uuid4().hex),query=query)


class Client:
    """2026-11-04: 명시 loopback 주소에만 접속하고 상태·보안 헤더를 검사한다. 사용: run."""
    def __init__(self,base):
        """2026-11-04: 프록시를 우회하고 외부 주소를 거절한다. 사용: run."""
        if not base.startswith('http://127.0.0.1:'): raise ValueError('Loopback mock required')
        self.base=base;self.token=None
        self.opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self,method,path,body=None,expected=200,kind=None,headers=None):
        """2026-11-04: 본문/토큰은 진단에 출력하지 않고 계약 오류만 알린다. 사용: run."""
        values={'Content-Type':'application/json; charset=utf-8'}
        if self.token: values['Authorization']='Bearer '+self.token
        values.update(headers or {})
        data=None if body is None else json.dumps(body,ensure_ascii=False).encode('utf-8')
        request=urllib.request.Request(self.base+path,data=data,headers=values,method=method)
        try: response=self.opener.open(request,timeout=12)
        except urllib.error.HTTPError as error: response=error
        with response:
            raw=response.read();result=json.loads(raw) if raw else None
            if response.status not in ([expected] if isinstance(expected,int) else expected):
                code=(result or {}).get('error',{}).get('code','missing')
                raise AssertionError(f'{method} {path}: HTTP {response.status}; code={code}')
            if response.headers.get('Cache-Control')!='no-store': raise AssertionError('Missing no-store')
        if kind: validate(kind,result)
        return result


def run(details,samples,cluster):
    """2026-11-04: 자동 모델 재시도 없이 명시 시도·조회·재로그인 복원을 검사한다. 사용: mock_server."""
    client=Client(details['baseUrl'])
    login=client.request('POST','/demo-sessions',details['login'],expected=201)
    client.token=login['accessToken']
    accepted=client.request('POST','/analysis-jobs',samples['accept'],expected=[200,202],kind='jobResponse')
    job=accepted['jobId'];state=accepted
    # 일반 항목 10개 미만은 실제 Q2의 60초 접수 대기를 그대로 거친다.
    deadline=time.monotonic()+75
    while state['action']!='submitInput':
        if time.monotonic()>deadline: raise AssertionError('No input permit')
        state=client.request('GET','/analysis-jobs/'+job,kind='jobResponse')
        job=state['jobId']
        if state['action']!='submitInput': time.sleep(3)
    body=deepcopy(samples['input']);body['permit']=state['permit'];validate('inputRequest',body)
    state=client.request('POST',f'/analysis-jobs/{job}/input',body,expected=[200,202],kind='jobResponse')
    observed=[]

    def finish(current):
        deadline=time.monotonic()+20
        while current['state'] in ('queued','awaitingInput','running'):
            if time.monotonic()>deadline: raise AssertionError('Mock analysis did not finish')
            current=client.request('GET','/analysis-jobs/'+current['jobId'],kind='jobResponse',
                                   headers={'Prefer':'wait=5'})
            observed.append(current['state'])
            if current['state']=='running': time.sleep(0.05)
        return current

    state=finish(state);job=state['jobId'];scenario=details['scenario']
    expected_calls=1
    if scenario in ('invalid_once','timeout_once'):
        target='failed' if scenario=='invalid_once' else 'outcomeUnknown'
        if state['state']!=target or state['action']!='retry' or not state['review']['requiresUserInput']:
            raise AssertionError('Expected explicit failure review')
        retry=deepcopy(samples['input']);retry['idempotencyKey']='mock-retry-'+uuid.uuid4().hex
        if scenario=='timeout_once':
            retry['acknowledgeDuplicateRisk']=False
            denied=client.request('POST',f'/analysis-jobs/{job}/retry',retry,
                                  expected=409,kind='errorResponse')
            if denied['error']['code']!='RELATION_CONFLICT': raise AssertionError('Expected acknowledgement conflict')
            retry['acknowledgeDuplicateRisk']=True
        validate('retryRequest',retry)
        state=finish(client.request('POST',f'/analysis-jobs/{job}/retry',retry,
            expected=[200,202],kind='jobResponse'));expected_calls=2
    if state['state']!='succeeded': raise AssertionError('Mock did not succeed')
    result=client.request('POST','/analysis-results/query',samples['query'],kind='queryResponse')
    if result['resultAvailability']!='available' or len(result['result']['items'])!=1:
        raise AssertionError('Saved interpretation unavailable')
    meaning=result['result']['items'][0]['interpretation']['meaning']
    if meaning['status']!=('unknown' if scenario=='unknown' else 'candidate'):
        raise AssertionError('Unknown was confused with failure')
    for _ in range(3): client.request('GET','/analysis-jobs/'+job,kind='jobResponse')
    client.request('DELETE','/demo-sessions/current',expected=204)
    client.token=None
    login=client.request('POST','/demo-sessions',details['login'],expected=201)
    client.token=login['accessToken']
    restored=client.request('POST','/analysis-results/query',samples['query'],kind='queryResponse')
    if restored['resultId']!=result['resultId']: raise AssertionError('Result not restored after login')
    calls=cluster.sql('SELECT count(*) FROM payse.analysis_attempts;', 'payse_auth_test_protocol')
    if calls!=[str(expected_calls)]: raise AssertionError('Unexpected extra provider attempt')
    client.request('DELETE','/demo-sessions/current',expected=204)
    client.token=None
    client.request('GET','/analysis-jobs/'+job,expected=401,kind='errorResponse')
    return dict(passed=True,scenario=scenario,providerAttempts=expected_calls,
        externalProviderCalls=0,reloginRestored=True,readRequestsAddedAttempts=0,
        anonymousRejected=True,observedStates=observed)


def current_samples(details, source):
    """2026-11-04: 실제 HTTP Snapshot 문맥을 그대로 사용해 파일 시각 표현 차이를 없앤다. 사용: mock_server."""
    client=Client(details['baseUrl'])
    login=client.request('POST','/demo-sessions',details['login'],expected=201)
    client.token=login['accessToken']
    try:
        snapshot=client.request('GET','/snapshot')
        current=deepcopy(source)
        for field in ('dataVersion','sourceVersion','ruleVersion','asOf'):
            current[field]=snapshot[field]
        return sample_requests(current)
    finally:
        client.request('DELETE','/demo-sessions/current',expected=204)
