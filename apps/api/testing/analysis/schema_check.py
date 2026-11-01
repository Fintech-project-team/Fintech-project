"""2026-11-01: 분석 계약에 쓰는 JSON Schema 부분집합의 오프라인 검사. 사용: 평가 검사.

범용 JSON Schema 라이브러리나 런타임 인증 검사를 대신하지 않는다.
이 프로젝트의 스키마에 없는 키워드는 조용히 무시하지 않고 거절한다.
"""
import re


def check(schema, value, path='$'):
    """2026-11-01: 허용 구조·타입·범위만 검사한다. 사용: 계약 테스트와 평가 도구."""
    supported = {'$schema', 'title', 'description', 'type', 'properties', 'required',
                 'additionalProperties', 'items', 'minItems', 'maxItems', 'uniqueItems',
                 'enum', 'minimum', 'maximum', 'minLength', 'maxLength', 'pattern'}
    if set(schema) - supported:
        raise ValueError(f'{path}: unsupported schema keyword')
    kinds = schema.get('type', [])
    kinds = [kinds] if isinstance(kinds, str) else kinds
    matches = {'null': value is None, 'boolean': type(value) is bool,
               'integer': type(value) is int, 'string': isinstance(value, str),
               'array': isinstance(value, list), 'object': isinstance(value, dict)}
    if kinds and not any(matches.get(kind, False) for kind in kinds):
        raise ValueError(f'{path}: type')
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError(f'{path}: enum')
    if isinstance(value, dict):
        properties = schema.get('properties', {})
        if set(schema.get('required', [])) - value.keys():
            raise ValueError(f'{path}: missing field')
        if schema.get('additionalProperties') is False and value.keys() - properties.keys():
            raise ValueError(f'{path}: unexpected field')
        for key in value.keys() & properties.keys():
            check(properties[key], value[key], f'{path}.{key}')
    if isinstance(value, list):
        if not schema.get('minItems', 0) <= len(value) <= schema.get('maxItems', len(value)):
            raise ValueError(f'{path}: array size')
        if schema.get('uniqueItems') and any(row in value[:index] for index, row in enumerate(value)):
            raise ValueError(f'{path}: duplicate value')
        for index, row in enumerate(value):
            check(schema.get('items', {}), row, f'{path}[{index}]')
    if isinstance(value, str):
        if not schema.get('minLength', 0) <= len(value) <= schema.get('maxLength', len(value)):
            raise ValueError(f'{path}: string size')
        if 'pattern' in schema and re.search(schema['pattern'], value) is None:
            raise ValueError(f'{path}: pattern')
    if type(value) is int and not schema.get('minimum', value) <= value <= schema.get('maximum', value):
        raise ValueError(f'{path}: integer range')
