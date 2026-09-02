#!/usr/bin/env python3
"""Regression tests for the Swift public API guard."""

from __future__ import annotations

import unittest

from check_swift_api import compare


def payload(identifier: str, declaration: str) -> dict:
    return {
        "schema_version": 1,
        "modules": {
            "Example": {
                "symbols": [
                    {
                        "identifier": identifier,
                        "kind": "swift.method",
                        "path": ["Store", "read()"],
                        "declaration": declaration,
                    }
                ]
            }
        },
    }


class SwiftAPICompatibilityTests(unittest.TestCase):
    def test_ignores_foundation_overlay_identifier_difference(self) -> None:
        expected = payload("s:darwin-foundation-overlay", "func read() -> Data")
        actual = payload("s:new-foundation-essentials", "func read() -> Data")

        self.assertEqual(compare(expected, actual), [])

    def test_still_reports_a_signature_change(self) -> None:
        expected = payload("s:old", "func read() -> Data")
        actual = payload("s:new", "func read() -> String")

        findings = compare(expected, actual)
        self.assertEqual(len(findings), 2)
        self.assertTrue(findings[0].startswith("removed "))
        self.assertTrue(findings[1].startswith("added "))


if __name__ == "__main__":
    unittest.main()
