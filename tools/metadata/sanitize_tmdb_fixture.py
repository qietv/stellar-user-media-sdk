#!/usr/bin/env python3
"""Convert captured TMDB JSON exchanges into canonical, credential-free fixtures."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlsplit


SENSITIVE_NAMES = {
    "api_key",
    "authorization",
    "cookie",
    "password",
    "request_token",
    "session_id",
    "token",
    "access_token",
    "refresh_token",
}
SAFE_RESPONSE_HEADERS = {"content-type", "retry-after"}
FIXTURE_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,79}$")
MAX_BODY_BYTES = 8 * 1024 * 1024


class FixtureError(ValueError):
    """Raised when a recording cannot be made safe and deterministic."""


def _normalized_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.lower())


def _is_sensitive(name: str) -> bool:
    normalized = _normalized_name(name)
    sensitive = {_normalized_name(value) for value in SENSITIVE_NAMES}
    return normalized in sensitive or normalized.endswith("token")


def _sanitize_json(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            str(key): _sanitize_json(item)
            for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
            if not _is_sensitive(str(key))
        }
    if isinstance(value, list):
        return [_sanitize_json(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise FixtureError("response body contains an unsupported JSON value")


def _request_parts(request: dict[str, Any]) -> tuple[str, str, dict[str, str]]:
    method = str(request.get("method", "GET")).upper()
    if method != "GET":
        raise FixtureError("TMDB fixture requests must use GET")

    if "url" in request:
        parsed = urlsplit(str(request["url"]))
        if parsed.scheme != "https" or parsed.hostname != "api.themoviedb.org":
            raise FixtureError("TMDB recording URL must use the official HTTPS origin")
        if parsed.username or parsed.password or parsed.fragment:
            raise FixtureError("TMDB recording URL contains forbidden components")
        path = parsed.path
        pairs = parse_qsl(parsed.query, keep_blank_values=True)
        query = {name: value for name, value in pairs if not _is_sensitive(name)}
    else:
        path = str(request.get("path", ""))
        raw_query = request.get("query", {})
        if not isinstance(raw_query, dict):
            raise FixtureError("TMDB request query must be an object")
        query = {
            str(name): str(value)
            for name, value in raw_query.items()
            if not _is_sensitive(str(name))
        }

    if not path.startswith("/3/") or "\0" in path or "?" in path or "#" in path:
        raise FixtureError("TMDB request path is invalid")
    return method, path, dict(sorted(query.items()))


def _response_parts(response: dict[str, Any]) -> dict[str, Any]:
    status_code = response.get("status_code")
    if not isinstance(status_code, int) or not 100 <= status_code <= 599:
        raise FixtureError("TMDB response status is invalid")
    raw_headers = response.get("headers", {})
    if not isinstance(raw_headers, dict):
        raise FixtureError("TMDB response headers must be an object")
    headers = {
        str(name).lower(): str(value)
        for name, value in raw_headers.items()
        if str(name).lower() in SAFE_RESPONSE_HEADERS
    }

    body = response.get("body")
    if isinstance(body, str):
        if len(body.encode("utf-8")) > MAX_BODY_BYTES:
            raise FixtureError("TMDB response body exceeds the fixture limit")
        try:
            body = json.loads(body)
        except json.JSONDecodeError as error:
            raise FixtureError("TMDB response body is not JSON") from error
    serialized = json.dumps(body, ensure_ascii=False, allow_nan=False).encode("utf-8")
    if len(serialized) > MAX_BODY_BYTES:
        raise FixtureError("TMDB response body exceeds the fixture limit")
    return {
        "status_code": status_code,
        "headers": dict(sorted(headers.items())),
        "body": _sanitize_json(body),
    }


def sanitize_document(document: dict[str, Any]) -> dict[str, Any]:
    """Return the portable fixture subset of a captured exchange document."""
    exchanges = document.get("exchanges")
    if not isinstance(exchanges, list) or not exchanges:
        raise FixtureError("TMDB recording must contain exchanges")

    sanitized: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    for exchange in exchanges:
        if not isinstance(exchange, dict):
            raise FixtureError("TMDB exchange must be an object")
        name = str(exchange.get("name", ""))
        if not FIXTURE_NAME.fullmatch(name) or name in seen_names:
            raise FixtureError("TMDB exchange name is invalid or duplicated")
        seen_names.add(name)
        request = exchange.get("request")
        response = exchange.get("response")
        if not isinstance(request, dict) or not isinstance(response, dict):
            raise FixtureError("TMDB exchange request and response are required")
        method, path, query = _request_parts(request)
        sanitized.append(
            {
                "name": name,
                "request": {"method": method, "path": path, "query": query},
                "response": _response_parts(response),
            }
        )

    return {
        "schema_version": 1,
        "provider": "tmdb",
        "recording_policy": "sanitized_response_only",
        "exchanges": sanitized,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Raw JSON recording")
    parser.add_argument("output", type=Path, help="Sanitized fixture destination")
    args = parser.parse_args()
    try:
        document = json.loads(args.input.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            raise FixtureError("TMDB recording root must be an object")
        sanitized = sanitize_document(document)
        output = json.dumps(sanitized, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    except (OSError, json.JSONDecodeError, FixtureError, ValueError) as error:
        parser.exit(1, f"TMDB fixture sanitization failed: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
