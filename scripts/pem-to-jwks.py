#!/usr/bin/env python3
"""
PEM(RSA public key) → JWKS(JSON) 변환.

JWKS 자동화 파이프라인 (ADR-0010 Rev 2, Option E) 내부에서 사용.
Istio RequestAuthentication.jwks 필드에 넣을 single-line JSON 생성.

Why:
- user-service가 JWT 서명 시 박는 kid와 JWKS의 kid가 일치해야 Istio 검증 성공.
- 현재 Goti는 kid 고정 문자열 패턴 (Phase A). 회전 시 kid를 수동 증가.
- PEM은 SSM(/prod/server/JWT_RSA_PUBLIC_KEY)이 단일 진실의 원천.

Output:
- values.yaml의 현재 포맷과 **바이트 일치** 필수.
- JSON 키 순서: alg, kty, kid, e, use, n (insertion order 유지)
- separators=(',',':') → 공백 없음
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from jwcrypto import jwk


def _normalize_pem(pem_bytes: bytes) -> bytes:
    """AWS SSM `--output text`가 개행을 리터럴 `\\n`으로 흘릴 때 실개행 복원.

    Why: SSM SecureString에 PEM을 넣으면 개행이 `\\n` 리터럴로 보존되는데
    `aws ssm get-parameter --output text`는 이걸 그대로 stdout에 흘린다.
    jwcrypto는 MalformedFraming 에러. workflow 재현성을 위해 스크립트가 직접 복원.
    이미 실개행이 있는 PEM에는 no-op."""
    text = pem_bytes.decode("utf-8", errors="strict")
    if "\\n" in text and "\n" not in text:
        text = text.replace("\\n", "\n")
    return text.encode("utf-8")


def pem_to_jwks(pem_bytes: bytes, kid: str, alg: str = "RS256", use: str = "sig") -> str:
    """PEM 공개키 → single-line JWKS JSON 문자열."""
    pem_bytes = _normalize_pem(pem_bytes)
    key = jwk.JWK.from_pem(pem_bytes)
    if key["kty"] != "RSA":
        raise ValueError(f"RSA 키만 지원: kty={key['kty']}")

    # 키 순서 고정: alg, kty, kid, e, use, n (현재 values.yaml 포맷)
    entry = {
        "alg": alg,
        "kty": "RSA",
        "kid": kid,
        "e": key["e"],
        "use": use,
        "n": key["n"],
    }
    jwks = {"keys": [entry]}
    return json.dumps(jwks, separators=(",", ":"))


def main() -> int:
    parser = argparse.ArgumentParser(description="PEM → JWKS 변환")
    parser.add_argument("pem_file", type=Path, help="RSA 공개키 PEM 파일 경로")
    parser.add_argument("--kid", default="goti-jwt-key-1", help="JWT kid (default: goti-jwt-key-1)")
    parser.add_argument("--alg", default="RS256", help="서명 알고리즘 (default: RS256)")
    parser.add_argument("--use", default="sig", help="키 용도 (default: sig)")
    args = parser.parse_args()

    if not args.pem_file.exists():
        print(f"error: PEM 파일 없음: {args.pem_file}", file=sys.stderr)
        return 1

    pem_bytes = args.pem_file.read_bytes()
    jwks_str = pem_to_jwks(pem_bytes, kid=args.kid, alg=args.alg, use=args.use)
    print(jwks_str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
