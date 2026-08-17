from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "metadata" / "sanitize_tmdb_fixture.py"
SPEC = importlib.util.spec_from_file_location("sanitize_tmdb_fixture", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SanitizeTMDBFixtureTests(unittest.TestCase):
    def test_secrets_and_unstable_headers_are_removed(self) -> None:
        marker = "SHOULD_NOT_SURVIVE"
        sanitized = MODULE.sanitize_document(
            {
                "exchanges": [
                    {
                        "name": "movie_search",
                        "request": {
                            "method": "GET",
                            "url": (
                                "https://api.themoviedb.org/3/search/movie"
                                f"?query=Arrival&api_key={marker}"
                            ),
                            "headers": {
                                "Authorization": f"Bearer {marker}",
                                "Cookie": f"session={marker}",
                            },
                        },
                        "response": {
                            "status_code": 200,
                            "headers": {
                                "Content-Type": "application/json",
                                "X-Request-ID": marker,
                            },
                            "body": {
                                "results": [{"id": 329865, "title": "Arrival"}],
                                "access_token": marker,
                            },
                        },
                    }
                ]
            }
        )

        encoded = json.dumps(sanitized, sort_keys=True)
        self.assertNotIn(marker, encoded)
        exchange = sanitized["exchanges"][0]
        self.assertEqual(exchange["request"]["path"], "/3/search/movie")
        self.assertEqual(exchange["request"]["query"], {"query": "Arrival"})
        self.assertEqual(
            exchange["response"]["headers"], {"content-type": "application/json"}
        )
        self.assertNotIn("access_token", exchange["response"]["body"])

    def test_non_official_origins_and_non_json_bodies_are_rejected(self) -> None:
        template = {
            "exchanges": [
                {
                    "name": "invalid_origin",
                    "request": {
                        "method": "GET",
                        "url": "https://example.invalid/3/search/movie",
                    },
                    "response": {"status_code": 200, "body": {}},
                }
            ]
        }
        with self.assertRaises(MODULE.FixtureError):
            MODULE.sanitize_document(template)

        template["exchanges"][0]["request"] = {
            "method": "GET",
            "path": "/3/search/movie",
        }
        template["exchanges"][0]["response"]["body"] = "not JSON"
        with self.assertRaises(MODULE.FixtureError):
            MODULE.sanitize_document(template)


if __name__ == "__main__":
    unittest.main()
