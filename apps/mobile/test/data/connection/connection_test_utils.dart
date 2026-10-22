import 'dart:convert';
import 'dart:io';

/// 2026-10-22: apps/api 원본 스냅샷 [stem]을 새 맵으로 읽어 반환한다(읽기만, 테스트마다 독립 사본).
/// 앱 에셋 복사본과 바이트가 같은 원본이며, 에셋에 없는 사례(salary-confirmed 등)도 투영 검증에 쓴다.
Map<String, Object?> readSource(String stem) => (jsonDecode(
  File('../api/fixtures/generated/snapshots/$stem.json').readAsStringSync(),
) as Map).cast<String, Object?>();

/// 2026-10-22: [json]의 객체 배열 [key]를 반환한다. 없으면 빈 목록이다.
List<Map<String, Object?>> rows(Map<String, Object?> json, String key) => [
  for (final item in (json[key] as List?) ?? const [])
    (item as Map).cast<String, Object?>(),
];

/// 2026-10-22: 응답의 제한 표식을 'ownerType|ownerId|field|targetKind' 문자열 집합으로 반환한다.
Set<String> restrictionKeys(Map<String, Object?> snapshot) => {
  for (final r in rows(snapshot, 'accessRestrictions'))
    '${r['ownerType']}|${r['ownerId']}|${r['field']}|${r['targetKind']}',
};

/// 2026-10-22: 원본 [source]에서 [codes] 기관에 속하지 않은 계좌·카드 ID를 반환한다(숨겨져야 할 ID).
Set<String> hiddenSourceIds(Map<String, Object?> source, Set<String> codes) => {
  for (final a in rows(source, 'accounts'))
    if (!codes.contains(a['institutionCode'])) a['accountId'] as String,
  for (final c in rows(source, 'cards'))
    if (!codes.contains(c['institutionCode'])) c['cardId'] as String,
};
