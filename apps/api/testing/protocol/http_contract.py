"""2026-11-04: 현행 분석 HTTP 봉투의 공개 스키마 생성·검사. 사용: CLI, mock smoke.

의미 본문은 기존 build_schemas 원본을 재사용하며 새 업무 규격을 만들지 않는다.
"""
import argparse
import json
from pathlib import Path
import sys

DIRECTORY = Path(__file__).resolve().parent
sys.path.insert(0, str(DIRECTORY.parent / 'analysis'))
from build_schemas import schemas, obj, array, TEXT, UUID
from schema_check import check


def ref(name):
    """2026-11-04: 한 번 정의한 공통 타입을 참조한다. 사용: definitions."""
    return {'$ref': '#/$defs/' + name}


def optional(properties, required):
    """2026-11-04: 명시 optional 필드를 허용하되 이름을 모르는 필드는 거절한다. 사용: definitions."""
    return dict(type='object', properties=properties, required=required, additionalProperties=False)


def definitions():
    """2026-11-04: 실제 AnalysisJobs/Results의 요청·응답 경계를 정의한다. 사용: document."""
    semantic = schemas()
    txn = semantic['transactionMeaning.input.schema.json']
    out = lambda task: semantic[task + '.output.schema.json']['properties']['items']['items']
    text = {'type':'string'}
    timestamp = {'type':'string','pattern':r'^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$'}
    boolean = {'type':'boolean'}
    natural = {'type':'integer','minimum':0}
    hash_value = {'type':'string','pattern':'^sha256:[0-9a-f]{64}$'}
    task = {'type':'string','enum':['transactionMeaning','recurringMeaning']}
    availability = {'type':'string','enum':['unchecked','available','partial','missing',
        'inactive','stale','expired','deleted']}
    states = ['queued','awaitingInput','running','succeeded','failed','outcomeUnknown','cancelled','expired']
    failure = {'type':'string','enum':['failed','outcomeUnknown','cancelled','expired']}
    common = dict(context=ref('context'),input=ref('semanticInput'),idempotencyKey=ref('idempotencyKey'))
    result_item = obj(dict(itemId=UUID, interpretation={'oneOf':[ref('transactionOutputItem'),
        ref('recurringOutputItem')]}, retentionReason=text, active=boolean, important=boolean,
        isReference=boolean, referencePolicy={'type':'string','enum':['optional','required']},
        storedAt=timestamp,normalExpiresAt=timestamp))
    return {
        'context':txn['properties']['context'],
        'idempotencyKey':{'type':'string','pattern':'^[A-Za-z0-9._-]{1,128}$'},
        'semanticInput':{'oneOf':[ref('transactionInput'),ref('recurringInput')]},
        'transactionInput':txn,
        'recurringInput':semantic['recurringMeaning.input.schema.json'],
        'transactionOutputItem':out('transactionMeaning'),
        'recurringOutputItem':out('recurringMeaning'),
        'acceptRequest':optional(dict(context=ref('context'),
            triggerKind={'type':'string','enum':['A','B','recovery']},semanticTaskKind=task,
            items=array(obj(dict(itemKey=TEXT,evidenceTransactionIds=array(UUID,minimum=1),
                                 candidateIds=array(TEXT,maximum=1))),minimum=1),
            inputHashHint=hash_value,reasonCodes=array(TEXT,maximum=0),
            idempotencyKey=ref('idempotencyKey'),previousJobId=UUID,input=ref('semanticInput')),
            ['context','triggerKind','semanticTaskKind','items','inputHashHint','reasonCodes','idempotencyKey']),
        'inputRequest':optional(dict(common,permit=hash_value,acknowledgeDuplicateRisk=boolean),
                                list(common)),
        'retryRequest':optional(dict(common,permit=hash_value,acknowledgeDuplicateRisk=boolean),
                                list(common)),
        'queryRequest':optional(dict(context=ref('context'),semanticTaskKind=task,
            input=ref('semanticInput'),resultId=UUID),['context','semanticTaskKind','input']),
        'jobResponse':optional(dict(contractVersion={'type':'string','enum':['PAYSE-ANALYSIS-1']},
            jobId=UUID,state={'type':'string','enum':states},
            action={'type':'string','enum':['wait','submitInput','readResult','retry','refreshInput','none']},
            resultAvailability=availability,resultId=UUID,permit=hash_value,permitExpiresAt=timestamp,
            progress=obj(dict(accepted=natural,completed=natural,unresolved=natural)),
            review=optional(dict(reason=failure,requiresUserInput={'type':'boolean','enum':[True]},
                itemsAvailable=boolean,retryRequiresAcknowledgement=boolean,
                items=array(obj(dict(itemKey=TEXT)))),
                ['reason','requiresUserInput','itemsAvailable','retryRequiresAcknowledgement'])),
            ['contractVersion','jobId','state','action','resultAvailability']),
        'queryResponse':optional(dict(contractVersion={'type':'string','enum':['PAYSE-ANALYSIS-1']},
            resultAvailability=availability,context=ref('context'),resultId=UUID,
            provenance=obj(dict(schemaVersion=TEXT,dataVersion=txn['properties']['context']['properties']['dataVersion'],
                sourceVersion=TEXT,ruleVersion=TEXT,asOf=timestamp,analysisInputHash=hash_value,
                versions=obj(dict(model=TEXT,prompt=TEXT,response=TEXT,policy=TEXT)))),
            result=obj(dict(meaningPolicyVersion={'type':'string','enum':['PAYSE-MEANING-1']},
                items=array(result_item),itemAvailability=array(optional(dict(itemKey=TEXT,
                    state={'type':'string','enum':['available','missing','inactive','stale','expired','deleted']},
                    itemId=UUID),['itemKey','state']))))),
            ['contractVersion','resultAvailability','context']),
        'errorResponse':obj(dict(error=obj(dict(code=TEXT,message=TEXT,requestId=UUID,
                                               details=array({},maximum=0))))),
    }


def document():
    """2026-11-04: 기존 버전과 함께 참조할 JSON Schema 문서를 반환한다. 사용: main, validate."""
    return {'$schema':'https://json-schema.org/draft/2020-12/schema',
            '$id':'urn:payse:analysis-http:1',
            'title':'PAYSE-ANALYSIS-1 HTTP envelopes (2026-11-04)', '$defs':definitions()}


def validate(name, value):
    """2026-11-04: 생성 문서의 명명 타입만 검증한다. 인증/버전/동작 의미 검증은 서버 책임이다."""
    defs = definitions()

    def visit(schema, item):
        if '$ref' in schema:
            visit(defs[schema['$ref'].removeprefix('#/$defs/')], item)
            return
        if 'oneOf' in schema:
            matches = 0
            for variant in schema['oneOf']:
                try:
                    visit(variant,item);matches += 1
                except ValueError:
                    pass
            if matches != 1: raise ValueError('Expected exactly one schema alternative')
            return
        shallow = dict(schema)
        if 'properties' in schema: shallow['properties']={key:{} for key in schema['properties']}
        if 'items' in schema: shallow['items']={}
        check(shallow,item)
        if isinstance(item,dict):
            for key in item.keys() & schema.get('properties',{}).keys():
                visit(schema['properties'][key],item[key])
        if isinstance(item,list):
            for child in item: visit(schema.get('items',{}),child)
    visit(defs[name],value)


def main():
    """2026-11-04: --write 생성 또는 게시 스키마 동일성 확인. 사용: CLI."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--write',action='store_true')
    args=parser.parse_args();path=DIRECTORY.parents[1]/'contracts/analysis-http.schema.json'
    value=document()
    if args.write:
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    elif json.loads(path.read_text(encoding='utf-8'))!=value:
        raise ValueError('HTTP schema is stale')
    print('PASS: analysis HTTP envelope schema')


if __name__=='__main__': main()
