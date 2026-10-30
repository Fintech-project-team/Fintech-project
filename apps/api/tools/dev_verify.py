"""2026-10-29: 별도 개발 DB의 실제 HTTP 인증·금융 저장을 검증한다. 사용처: 로컬 서버 준비 도구.

운영/공유 DB에는 사용하지 않는다. 호출자는 직접 준비한 개발 DB와 loopback API인지 확인한다.
fixture_dir에는 server-seeds.json과 snapshots/<initialCase>.json이 있어야 한다.
코드 verifier 준비와 DB 원천 지문 비교는 호출자 책임이다. 이 모듈은 DB에 직접 접속하지 않는다.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


_CODES = {"데모알파": "000001", "데모베타": "000002", "데모감마": "000003"}
_MAX_BODY = 8 * 1024 * 1024


class VerificationError(RuntimeError):
    """2026-10-29: 금융 원문·자격을 담지 않는 검사 실패다. 사용처: verify와 검증 도우미."""

    def __init__(self, step: str, report: dict | None = None):
        """2026-10-29: 고정 단계명과 비민감 결과만 보관한다. 사용처: _require, verify."""
        super().__init__("PAYSE 개발 API 검증 실패: " + step)
        self.report = report


class _NoRedirect(HTTPRedirectHandler):
    """2026-10-29: 토큰을 다른 주소로 전달하는 리다이렉트를 금지한다. 사용처: _Client."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        """2026-10-29: 모든 리다이렉트를 원래 HTTP 결과로 남긴다. 사용처: urllib."""
        return None


@dataclass(repr=False)
class _User:
    """2026-10-29: 한 합성 계정의 검사 문맥을 메모리에만 둔다. 사용처: verify."""

    seed: dict
    source: dict
    code: str
    token: str | None = field(default=None, repr=False)
    session_id: str | None = field(default=None, repr=False)
    current: dict | None = field(default=None, repr=False)
    before: dict | None = field(default=None, repr=False)
    facts: str | None = field(default=None, repr=False)


class _Client:
    """2026-10-29: 외부 전달·응답 로깅 없는 loopback HTTP 클라이언트다. 사용처: verify."""

    def __init__(self, base_url: str):
        """2026-10-29: 직접 준비한 loopback 주소만 허용한다. 사용처: verify."""
        parsed = urlsplit(base_url)
        _require(parsed.scheme in {"http", "https"}
                 and parsed.hostname == "127.0.0.1"
                 and parsed.username is None and parsed.password is None
                 and not parsed.query and not parsed.fragment, "loopback 주소")
        self.base = base_url.rstrip("/")
        self.opener = build_opener(ProxyHandler({}), _NoRedirect())
        self.requests = 0
        self.auth_requests = 0

    def request(self, method: str, path: str, body: dict | None = None,
                token: str | None = None) -> tuple[int, dict | None]:
        """2026-10-29: JSON 요청과 비노출 응답을 교환한다. 사용처: 모든 HTTP 검사."""
        self.requests += 1
        if path.startswith("/demo-sessions"):
            self.auth_requests += 1
            _require(self.auth_requests <= 30, "인증 검사 호출 상한")
        payload = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "application/json; charset=utf-8"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = Request(self.base + path, data=payload, headers=headers, method=method)
        try:
            try:
                response = self.opener.open(request, timeout=20)
            except HTTPError as error:
                response = error
            with response:
                status = response.status
                raw = response.read(_MAX_BODY + 1)
                _require(len(raw) <= _MAX_BODY, "HTTP 응답 크기")
                _require(response.headers.get("Cache-Control") == "no-store", "캐시 금지 헤더")
                _require(not response.headers.get_all("Set-Cookie"), "쿠키 미발급")
                if status == 401:
                    _require(response.headers.get("WWW-Authenticate") == "Bearer", "인증 거절 헤더")
            parsed = None if not raw else json.loads(raw.decode("utf-8"))
            _require(parsed is None or isinstance(parsed, dict), "JSON 응답 객체")
            return status, parsed
        except VerificationError:
            raise
        except (OSError, URLError, ValueError, UnicodeError):
            raise VerificationError("HTTP 통신 또는 JSON 해석") from None


def _require(condition: bool, step: str) -> None:
    """2026-10-29: 원문 없는 고정 단계명으로 조건을 검증한다. 사용처: 모든 검사."""
    if not condition:
        raise VerificationError(step)


def _one(rows: list, predicate: Callable[[dict], bool], step: str) -> dict:
    """2026-10-29: ID·관계로 대상 한 건을 확정한다. 사용처: 계좌·카드·생성 결과 검사."""
    found = [row for row in rows if predicate(row)]
    _require(len(found) == 1, step)
    return found[0]


def _expect(result: tuple[int, dict | None], status: int, step: str,
            code: str | None = None) -> dict:
    """2026-10-29: 상태·공개 오류만 검증하고 본문을 출력하지 않는다. 사용처: HTTP 호출부."""
    actual, body = result
    _require(actual == status, step)
    if code is not None:
        _require(isinstance(body, dict) and body.get("error", {}).get("code") == code, step)
    if status == 204:
        _require(body is None, step)
        return {}
    _require(isinstance(body, dict), step)
    return body


def _credentials(user: _User) -> dict:
    """2026-10-29: 승인된 합성 자격만 요청에 넣는다. 사용처: 로그인·재확인."""
    return {"name": user.seed["name"], "phone": user.seed["phone"], "code": user.code}


def _users(directory: Path) -> list[_User]:
    """2026-10-29: 배열 순서 대신 이름과 사용자 ID 관계를 검증한다. 사용처: verify."""
    try:
        seeds = json.loads((directory / "server-seeds.json").read_text(encoding="utf-8"))["users"]
        _require(len(seeds) == 3 and {seed["name"] for seed in seeds} == set(_CODES), "합성 계정 명세")
        _require(len({seed["userId"] for seed in seeds}) == 3, "합성 사용자 ID 유일성")
        users = []
        for name, code in _CODES.items():
            seed = _one(seeds, lambda row: row["name"] == name, "합성 이름 매핑")
            _require(str(uuid.UUID(seed["userId"])) == seed["userId"], "합성 사용자 ID 형식")
            case = seed["initialCase"]
            _require(isinstance(case, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", case) is not None,
                     "초기 사례 경로")
            source = json.loads((directory / "snapshots" / (case + ".json")).read_text(encoding="utf-8"))
            _require(source["userId"] == seed["userId"] and source["schemaVersion"] == "PAYSE-DRAFT-3",
                     "초기 사례 소유자와 형식")
            users.append(_User(seed=seed, source=source, code=code))
        return users
    except VerificationError:
        raise
    except (OSError, ValueError, KeyError, TypeError):
        raise VerificationError("합성 준비 자료 읽기") from None


def _login(client: _Client, user: _User) -> None:
    """2026-10-29: 실제 인증 성공 토큰을 메모리에만 보관한다. 사용처: verify·재로그인."""
    body = _expect(client.request("POST", "/demo-sessions", _credentials(user)), 201, "합성 계정 로그인")
    _require(body.get("userId") == user.seed["userId"] and body.get("name") == user.seed["name"]
             and body.get("tokenType") == "Bearer", "로그인 사용자 매핑")
    _require(isinstance(body.get("accessToken"), str)
             and re.fullmatch(r"[A-Za-z0-9_-]{43}", body["accessToken"]) is not None, "로그인 토큰 형식")
    user.token = body["accessToken"]
    user.session_id = body.get("sessionId")


def _snapshot(client: _Client, user: _User) -> dict:
    """2026-10-29: 현재 세션의 v3 스냅샷을 확인한다. 사용처: 조회·쓰기 준비·원복."""
    result = _expect(client.request("GET", "/snapshot", token=user.token), 200, "스냅샷 조회")
    _require(result.get("userId") == user.seed["userId"]
             and result.get("schemaVersion") == "PAYSE-API-0.6-3", "스냅샷 사용자와 버전")
    _require(isinstance(result.get("dataVersion"), str) and result["dataVersion"].isdigit(), "자료 버전 형식")
    user.current = result
    return result


def _write(client: _Client, user: _User, path: str, values: dict,
           method: str = "PATCH") -> tuple[dict, dict]:
    """2026-10-29: 새 논리 작업의 최신 버전과 키로 저장한다. 사용처: 설정·검증 데이터·원복."""
    snapshot = _snapshot(client, user)
    request = {"expectedDataVersion": snapshot["dataVersion"], "ruleVersion": snapshot["ruleVersion"],
               "idempotencyKey": str(uuid.uuid4()), **copy.deepcopy(values)}
    result = _expect(client.request(method, path, request, user.token), 200, "금융 설정 저장")
    _require(result.get("replayed") is False and result.get("receipt", {}).get("operationKey") == request["idempotencyKey"],
             "새 작업 영수증")
    _require(result["receipt"]["resultVersion"] == str(int(snapshot["dataVersion"]) + 1), "원자 자료 버전 증가")
    current = result["snapshot"]
    _require(current["userId"] == user.seed["userId"] and current["schemaVersion"] == "PAYSE-API-0.6-3",
             "저장 응답 소유자와 형식")
    _require(current["sourceVersion"] == snapshot["sourceVersion"] and current["asOf"] == snapshot["asOf"],
             "저장 후 원천 버전과 시점 보존")
    user.current = current
    return request, result


def _command(client: _Client, user: _User, values: dict) -> dict:
    """2026-10-29: 거절 검사에도 현재 버전을 제공한다. 사용처: 403·409·422 검사."""
    current = _snapshot(client, user)
    return {"expectedDataVersion": current["dataVersion"], "ruleVersion": current["ruleVersion"],
            "idempotencyKey": str(uuid.uuid4()), **copy.deepcopy(values)}


def _changed(result: dict, resource: str) -> str:
    """2026-10-29: 표시명 대신 성공 영수증의 자원 ID를 얻는다. 사용처: 생성 후 검증·취소."""
    row = _one(result["receipt"]["changedRefs"], lambda item: item["resource"] == resource, "생성 자원 ID")
    value = row["id"]
    _require(str(uuid.UUID(value)) == value, "생성 ID 형식")
    return value


def _normalized(value):
    """2026-10-29: 비교용 시각 표기만 UTC로 정규화한다. 사용처: 원천 지문, fixture 비교."""
    if isinstance(value, dict):
        return {key: _normalized(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_normalized(item) for item in value]
    if isinstance(value, str) and re.match(r"^\d{4}-\d{2}-\d{2}T", value):
        instant = datetime.fromisoformat(value.replace("Z", "+00:00"))
        _require(instant.tzinfo is not None, "원천 시각 오프셋")
        return instant.astimezone(timezone.utc).isoformat()
    return value


def _complete(client: _Client, user: _User) -> tuple[dict, list[dict], int]:
    """2026-10-29: 후속 페이지를 모두 받고 fixture ID·금액·날짜를 대조한다. 사용처: 원천 보존 확인."""
    snapshot = _snapshot(client, user)
    seen = set()
    cursors = set()
    transactions = []
    page = snapshot
    count = 0
    while True:
        count += 1
        rows = page["transactions"]
        _require(isinstance(rows, list) and len(rows) <= 100, "거래 페이지 크기")
        ids = [row["transactionId"] for row in rows]
        _require(ids == sorted(ids) and len(set(ids)) == len(ids), "거래 UUID 정렬과 페이지 중복")
        _require(not seen.intersection(ids), "거래 페이지 간 중복")
        if transactions and ids:
            _require(transactions[-1]["transactionId"] < ids[0], "거래 페이지 순서")
        for row in rows:
            _require(row["userId"] == user.seed["userId"] and type(row["amountKRW"]) is int, "거래 소유권과 정수 금액")
        seen.update(ids)
        transactions.extend(rows)
        _require(page["dataVersion"] == snapshot["dataVersion"]
                 and page["sourceVersion"] == snapshot["sourceVersion"], "페이지 버전 일관성")
        cursor = page["page"]["nextCursor"]
        if cursor is None:
            break
        _require(isinstance(cursor, str) and cursor not in cursors and count < 20, "후속 페이지 종료성")
        cursors.add(cursor)
        page = _expect(client.request("GET", "/transactions?cursor=" + quote(cursor, safe=""), token=user.token),
                       200, "후속 거래 페이지")
        _require("accounts" not in page, "후속 페이지의 스냅샷 중복 금지")
    source_rows = user.source["transactions"]
    expected = {row["transactionId"]: row for row in source_rows}
    _require(len(expected) == len(source_rows) and set(expected) == seen, "fixture 거래 목록 완전성")
    fields = ("amountKRW", "direction", "recordKind", "status", "accountId", "cardId", "purchaseDate",
              "withdrawalDate", "refundDate", "bookingDate", "occurredAt", "occurredAtBasis",
              "balanceReflected", "reflectionReason", "originalTransactionId", "cancellationDate")
    for row in transactions:
        original = expected[row["transactionId"]]
        _require(all(_normalized(row.get(key)) == _normalized(original.get(key)) for key in fields),
                 "fixture 거래 금액 날짜 원천 보존")
    for row in snapshot["accounts"]:
        original = _one(user.source["accounts"], lambda item: item["accountId"] == row["accountId"], "fixture 계좌 관계")
        _require(row["balanceKRW"] == original["balanceKRW"]
                 and _normalized(row["asOf"]) == _normalized(original["asOf"]), "fixture 잔액과 시점 보존")
    _require(all("items" not in row for row in snapshot["statements"]), "v3 응답 청구 형식")
    return snapshot, transactions, count


def _facts(snapshot: dict, transactions: list[dict]) -> str:
    """2026-10-29: 사용자 편집 설정을 제외한 원천 지문을 만든다. 사용처: 재시작·원복 전후 비교."""
    accounts = [{key: value for key, value in row.items() if key not in {"included", "nickname"}}
                for row in snapshot["accounts"]]
    value = {"accounts": sorted(accounts, key=lambda row: row["accountId"]),
             "cards": sorted(snapshot["cards"], key=lambda row: row["cardId"]),
             "statements": sorted(snapshot["statements"], key=lambda row: row["statementId"]),
             "transactions": transactions, "relatedTransactions": snapshot["relatedTransactions"],
             "coverage": snapshot["coverage"], "sourceVersion": snapshot["sourceVersion"], "asOf": snapshot["asOf"],
             "receiptEvidence": snapshot["settings"]["salary"]["receiptEvidence"]}
    raw = json.dumps(_normalized(value), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _stored_state(snapshot: dict) -> dict:
    """2026-10-29: 매 요청 난수로 바뀌는 cursor 표현을 제외한다. 사용처: 재시작·재로그인 상태 비교."""
    result = copy.deepcopy(snapshot)
    if "page" in result:
        result["page"]["nextCursor"] = result["page"]["nextCursor"] is not None
    return result


def _main_account(user: _User, snapshot: dict) -> dict:
    """2026-10-29: fixture 급여 계좌 관계로 쓰기 대상을 유일하게 확정한다. 사용처: verify."""
    account_id = user.source["settings"]["salary"]["salaryAccountId"]
    _require(isinstance(account_id, str), "검증 대상 급여 계좌 근거")
    row = _one(snapshot["accounts"], lambda item: item["accountId"] == account_id, "급여 계좌 단일 관계")
    _require(row["userId"] == user.seed["userId"] and row["balanceKRW"] >= 50000, "검증 계좌 소유자와 준비 잔액")
    return row


def _allocations() -> dict:
    """2026-10-29: 필수 세 배열의 배정 변경 본문을 만든다. 사용처: 보호 설정 생성·수정."""
    return {"create": [], "update": [], "remove": []}


def _restore(client: _Client, user: _User, created: dict, account_id: str | None,
             card_id: str | None) -> list[str]:
    """2026-10-29: 생성 검증 설정을 논리 취소하고 변경 설정을 가능한 범위에서 복원한다. 사용처: verify finally."""
    notes = []
    if user.token is None or user.before is None:
        return notes
    current = _snapshot(client, user)
    obligation_id = created.get("obligationId")
    if obligation_id is not None:
        obligation = _one(current["obligations"], lambda row: row["obligationId"] == obligation_id, "원복 의무 확인")
        if obligation["status"] != "cancelled":
            detach = []
            for row in current["allocations"]:
                if row["obligationId"] == obligation_id:
                    _require(row["releasedKRW"] == 0 and row["reserveId"] == created.get("reserveId"), "검증 배정 이력 불변")
                    if row["amountKRW"] > 0:
                        detach.append({"allocationId": row["allocationId"], "unreleasedKRW": row["amountKRW"]})
            _write(client, user, "/obligations/" + obligation_id + "/cancel", {"detachAllocations": detach}, "POST")
    reserve_id = created.get("reserveId")
    if reserve_id is not None:
        current = _snapshot(client, user)
        reserve = _one(current["reserves"], lambda row: row["reserveId"] == reserve_id, "원복 보호 설정 확인")
        if reserve["cancelledAt"] is None:
            _write(client, user, "/reserves/" + reserve_id + "/cancel", {"detachAllocations": []}, "POST")
    if obligation_id is not None or reserve_id is not None:
        current = _snapshot(client, user)
        if obligation_id is not None:
            obligation = _one(current["obligations"], lambda row: row["obligationId"] == obligation_id, "취소 의무 조회")
            _require(obligation["status"] == "cancelled", "의무 논리 취소 저장")
        if reserve_id is not None:
            reserve = _one(current["reserves"], lambda row: row["reserveId"] == reserve_id, "취소 보호 설정 조회")
            _require(reserve["cancelledAt"] is not None, "보호 설정 논리 취소 저장")
        if "allocationId" in created:
            _require(not any(row["allocationId"] == created["allocationId"] for row in current["allocations"]),
                     "미지급 검증 배정 해제 저장")
    if account_id is not None:
        before_account = _one(user.before["accounts"], lambda row: row["accountId"] == account_id, "이전 계좌 설정")
        _write(client, user, "/accounts/" + account_id, {"nickname": before_account["nickname"]})
        salary = user.before["settings"]["salary"]
        _write(client, user, "/settings", {"salary": {key: salary[key] for key in ("salaryDay", "salaryAmountKRW", "salaryAccountId")}})
        if card_id is not None:
            before_plans = [row for row in user.before["settings"]["cardPlans"] if row["cardId"] == card_id]
            _require(len(before_plans) <= 1, "이전 카드 계획 유일성")
            day = before_plans[0]["plannedPaymentDay"] if before_plans else None
            _write(client, user, "/settings", {"cardPlans": [{"cardId": card_id, "plannedPaymentDay": day}]})
        selected = [row["accountId"] for row in user.before["accounts"] if row["included"]]
        if selected:
            _write(client, user, "/account-selection", {"accountIds": selected})
        else:
            notes.append("최초 빈 계좌 선택은 API가 허용하지 않아 검증 대상 계좌 선택을 유지했습니다.")
        current = _snapshot(client, user)
        account = _one(current["accounts"], lambda row: row["accountId"] == account_id, "복원 계좌 조회")
        _require(account["nickname"] == before_account["nickname"], "계좌 별칭 원복")
        _require(current["settings"] == user.before["settings"], "급여와 카드 계획 원복")
        if selected:
            _require({row["accountId"] for row in current["accounts"] if row["included"]} == set(selected), "계좌 선택 원복")
    notes.append("검증용 의무·보호 설정은 논리 취소하고 영수증·버전 이력은 보존했습니다.")
    return notes


def verify(base_url: str, fixture_dir: str | Path, restart_api_callback: Callable[[], None]) -> dict:
    """2026-10-29: 실제 개발 API의 계약·재로그인·재시작 보존을 검증한다. 사용처: 로컬 서버 준비 실행기.

    callback은 같은 URL·DB·키로 API만 재시작하고 준비 완료 뒤 반환해야 한다.
    응답·토큰·자격은 파일이나 로그에 남기지 않는다. 정상 경로 인증 API 호출은 총 15회다.
    결과에는 검사 이름·건수·검증용 생성 자원 ID·원복 상태만 포함한다.
    """
    client = _Client(base_url)
    users = _users(Path(fixture_dir))
    main = _one(users, lambda user: user.seed["name"] == "데모알파", "주 검증 계정")
    other = _one(users, lambda user: user.seed["name"] == "데모베타", "격리 검증 계정")
    report = {"ok": False, "checks": [], "accountCount": 3, "pages": [], "created": {},
              "restoration": [], "institutionConnectionsRetained": True, "loggedOut": 0}
    created = report["created"]
    account_id = None
    card_id = None
    failure = None
    try:
        for user in users:
            _login(client, user)
            _expect(client.request("POST", "/demo-sessions", _credentials(user)), 401,
                    "기존 세션 우선", "AUTH_REJECTED")
            confirmed = _expect(client.request("POST", "/demo-sessions/current/reverify", _credentials(user), user.token),
                                200, "현재 세션 재확인")
            _require(confirmed == {"userId": user.seed["userId"], "sessionId": user.session_id, "verified": True},
                     "재확인 결과와 새 토큰 미발급")
            snapshot = _snapshot(client, user)
            institutions = snapshot["institutions"]
            codes = [row["code"] for row in institutions]
            _require(codes and len(set(codes)) == len(codes)
                     and any(row["kind"] == "bank" and row["accountCount"] > 0 for row in institutions),
                     "연결 가능한 은행과 기관 목록")
            _write(client, user, "/institution-links", {"institutionCodes": sorted(codes)}, "POST")
            snapshot, transactions, pages = _complete(client, user)
            user.before = copy.deepcopy(snapshot)
            user.facts = _facts(snapshot, transactions)
            report["pages"].append({"case": user.seed["initialCase"], "transactions": len(transactions), "pages": pages})
        report["checks"].extend(["three_logins", "single_active_session", "reverify", "institution_links", "v3_pages"])

        account_id = _main_account(main, main.before)["accountId"]
        card = _one(main.before["cards"], lambda row: row["cardType"] == "debit", "체크카드 단일 준비 관계")
        card_id = card["cardId"]
        _require(card["userId"] == main.seed["userId"], "카드 소유자")
        _, selected = _write(client, main, "/account-selection", {"accountIds": [account_id]})
        _require({row["accountId"] for row in selected["snapshot"]["accounts"] if row["included"]} == {account_id},
                 "계좌 선택 집합 저장")
        stale_cursor = _snapshot(client, main)["page"]["nextCursor"]
        path = "/accounts/" + account_id
        replay_request, first = _write(client, main, path, {"nickname": "개발 확인 통장"})
        named = _one(first["snapshot"]["accounts"], lambda row: row["accountId"] == account_id, "별칭 저장 계좌")
        _require(named["nickname"] == "개발 확인 통장", "계좌 별칭 저장")
        _require(stale_cursor is not None, "페이지 충돌 검사 준비")
        _expect(client.request("GET", "/transactions?cursor=" + quote(stale_cursor, safe=""), token=main.token),
                409, "저장 뒤 이전 cursor", "STALE_DATA")
        _expect(client.request("GET", "/transactions?cursor=broken", token=main.token), 400, "변조 cursor", "INVALID_CURSOR")

        foreign_id = _main_account(other, other.before)["accountId"]
        denied = _command(client, main, {"nickname": "권한 확인"})
        before_version = main.current["dataVersion"]
        _expect(client.request("PATCH", "/accounts/" + foreign_id, denied, main.token),
                403, "타 사용자 계좌 수정 거절", "RESOURCE_FORBIDDEN")
        _require(_snapshot(client, main)["dataVersion"] == before_version, "소유권 거절 후 버전 보존")
        foreign_after = _snapshot(client, other)
        foreign_account = _one(foreign_after["accounts"], lambda row: row["accountId"] == foreign_id, "타 사용자 계좌 재조회")
        foreign_before = _one(other.before["accounts"], lambda row: row["accountId"] == foreign_id, "타 사용자 이전 계좌")
        _require(foreign_account["nickname"] == foreign_before["nickname"]
                 and foreign_after["dataVersion"] == other.before["dataVersion"], "타 사용자 설정과 버전 보존")
        replay = _expect(client.request("PATCH", path, replay_request, main.token), 200, "동일 작업 재시도")
        _require(replay["replayed"] is True and replay["receipt"]["receiptId"] == first["receipt"]["receiptId"],
                 "멱등 영수증 동일성")
        _expect(client.request("PATCH", path, {**replay_request, "nickname": "서로 다른 요청"}, main.token),
                409, "동일 키 다른 요청", "IDEMPOTENCY_CONFLICT")
        _expect(client.request("PATCH", path, {**replay_request, "idempotencyKey": str(uuid.uuid4())}, main.token),
                409, "이전 버전 새 작업", "STALE_DATA")
        unchanged = _snapshot(client, main)
        _require(unchanged["dataVersion"] == first["snapshot"]["dataVersion"], "멱등·버전 거절 후 버전 보존")
        named = _one(unchanged["accounts"], lambda row: row["accountId"] == account_id, "멱등 검사 뒤 계좌")
        _require(named["nickname"] == "개발 확인 통장", "멱등·버전 거절 후 값 보존")
        report["checks"].extend(["account_selection", "nickname", "ownership_403", "cursor_400_409", "idempotency_409"])

        salary = {"salaryDay": 31, "salaryAmountKRW": 3200000, "salaryAccountId": account_id}
        _, result = _write(client, main, "/settings", {"salary": salary})
        _require(all(result["snapshot"]["settings"]["salary"][key] == value for key, value in salary.items()), "급여 설정 저장")
        _, result = _write(client, main, "/settings", {"cardPlans": [{"cardId": card_id, "plannedPaymentDay": 29}]})
        card_plan = _one(result["snapshot"]["settings"]["cardPlans"], lambda row: row["cardId"] == card_id, "카드 계획 조회")
        _require(card_plan["plannedPaymentDay"] == 29, "카드 계획 저장")
        _, result = _write(client, main, "/obligations", {"label": "개발 확인 지출", "withdrawalAccountId": account_id,
                                                        "amountKRW": 30000, "dueDate": main.source["asOf"][:10]}, "POST")
        created["obligationId"] = _changed(result, "obligation")
        _, result = _write(client, main, "/obligations/" + created["obligationId"], {"label": "개발 확인 지출 수정", "amountKRW": 40000})
        obligation = _one(result["snapshot"]["obligations"], lambda row: row["obligationId"] == created["obligationId"], "수정 의무 조회")
        _require(obligation["amountKRW"] == 40000 and obligation["dueDate"] == main.source["asOf"][:10]
                 and obligation["label"] == "개발 확인 지출 수정", "의무 수정 금액과 날짜")
        changes = _allocations()
        changes["create"].append({"obligationId": created["obligationId"], "amountKRW": 20000})
        _, result = _write(client, main, "/reserves", {"accountId": account_id, "label": "개발 확인 준비금",
                                                     "amountKRW": 50000, "allocationChanges": changes}, "POST")
        created["reserveId"] = _changed(result, "reserve")
        allocation = _one(result["snapshot"]["allocations"], lambda row: row["reserveId"] == created["reserveId"]
                          and row["obligationId"] == created["obligationId"], "생성 배정 관계")
        created["allocationId"] = allocation["allocationId"]
        reserve = _one(result["snapshot"]["reserves"], lambda row: row["reserveId"] == created["reserveId"], "생성 보호 설정 조회")
        _require(reserve["amountKRW"] == 50000 and reserve["accountId"] == account_id
                 and allocation["amountKRW"] == 20000 and allocation["releasedKRW"] == 0, "보호 설정과 배정 생성")
        changes = _allocations()
        changes["update"].append({"allocationId": created["allocationId"], "amountKRW": 15000})
        _, result = _write(client, main, "/reserves/" + created["reserveId"], {"label": "개발 확인 준비금 수정", "amountKRW": 40000,
                                                                            "allocationChanges": changes})
        reserve = _one(result["snapshot"]["reserves"], lambda row: row["reserveId"] == created["reserveId"], "수정 보호 설정 조회")
        allocation = _one(result["snapshot"]["allocations"], lambda row: row["allocationId"] == created["allocationId"], "수정 배정 조회")
        _require(reserve["amountKRW"] == 40000 and reserve["label"] == "개발 확인 준비금 수정"
                 and allocation["amountKRW"] == 15000 and allocation["releasedKRW"] == 0, "보호 설정과 배정 수정 저장")
        denied = _command(client, main, {"detachAllocations": []})
        before_version = main.current["dataVersion"]
        _expect(client.request("POST", "/obligations/" + created["obligationId"] + "/cancel", denied, main.token),
                409, "배정 누락 취소 거절", "RELATION_CONFLICT")
        _require(_snapshot(client, main)["dataVersion"] == before_version, "관계 거절 후 버전 보존")
        remaining = _one(main.current["allocations"], lambda row: row["allocationId"] == created["allocationId"], "거절 뒤 배정 조회")
        remaining_obligation = _one(main.current["obligations"], lambda row: row["obligationId"] == created["obligationId"], "거절 뒤 의무 조회")
        _require(remaining["amountKRW"] == 15000 and remaining_obligation["status"] == "active", "취소 거절 뒤 전체 저장 상태 보존")
        report["checks"].extend(["salary_settings", "card_settings", "obligation_create_update", "reserve_create_update", "atomic_cancel_rejection"])

        persisted = _snapshot(client, main)
        cursor = persisted["page"]["nextCursor"]
        _require(cursor is not None, "재시작 페이지 준비")
        restart_api_callback()
        restored = _snapshot(client, main)
        _require(_stored_state(restored) == _stored_state(persisted), "API 재시작 후 세션과 저장 상태 보존")
        _expect(client.request("GET", "/transactions?cursor=" + quote(cursor, safe=""), token=main.token),
                200, "API 재시작 후 cursor 유지")
        replay = _expect(client.request("PATCH", path, replay_request, main.token), 200, "재시작 뒤 동일 작업 재시도")
        _require(replay["replayed"] is True and replay["receipt"]["receiptId"] == first["receipt"]["receiptId"],
                 "재시작 뒤 멱등 기록 보존")
        _expect(client.request("POST", "/demo-sessions", _credentials(main)), 401, "재시작 뒤 기존 세션 우선", "AUTH_REJECTED")
        old_token = main.token
        _expect(client.request("DELETE", "/demo-sessions/current", token=old_token), 204, "재로그인 전 종료")
        main.token = None
        _expect(client.request("GET", "/snapshot", token=old_token), 401, "종료된 토큰 거절", "SESSION_INVALID")
        _login(client, main)
        _require(main.token != old_token, "재로그인 토큰 교체")
        old_token = None
        _expect(client.request("GET", "/transactions?cursor=" + quote(cursor, safe=""), token=main.token),
                403, "이전 세션 cursor 거절", "RESOURCE_FORBIDDEN")
        _require(_stored_state(_snapshot(client, main)) == _stored_state(persisted), "재로그인 후 저장 상태 보존")
        report["checks"].extend(["api_restart_persistence", "restart_session_cursor", "restart_idempotency", "logout_relogin"])
    except Exception as error:
        failure = str(error) if isinstance(error, VerificationError) else "PAYSE 개발 API 검증 실패: 실행 단계"
    finally:
        try:
            report["restoration"] = _restore(client, main, created, account_id, card_id)
            if main.before is not None and account_id is not None:
                report["checks"].append("settings_restored_and_created_records_cancelled")
            for user in users:
                if user.token is not None and user.facts is not None:
                    snapshot, transactions, _ = _complete(client, user)
                    _require(_facts(snapshot, transactions) == user.facts, "검증 후 금융 원천 불변")
            if all(user.facts is not None for user in users):
                report["checks"].append("source_facts_unchanged")
        except Exception:
            report["restoration"].append("API 원복 또는 원천 재검증이 완료되지 않았습니다. 직접 DB 초기화하지 않았습니다.")
            if failure is None:
                failure = "PAYSE 개발 API 검증 실패: 원복 또는 원천 재검증"
        for user in users:
            if user.token is None:
                continue
            try:
                _expect(client.request("DELETE", "/demo-sessions/current", token=user.token), 204, "최종 세션 종료")
                report["loggedOut"] += 1
            except Exception:
                if failure is None:
                    failure = "PAYSE 개발 API 검증 실패: 최종 세션 종료"
            finally:
                user.token = None
        report["requests"] = client.requests
        report["authRequests"] = client.auth_requests
    if failure is not None:
        raise VerificationError(failure.removeprefix("PAYSE 개발 API 검증 실패: "), report) from None
    _require(report["loggedOut"] == 3, "세 합성 계정 최종 로그아웃")
    report["ok"] = True
    return report
