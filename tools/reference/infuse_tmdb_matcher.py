#!/usr/bin/env python3
"""Clean-room Infuse-compatible filename parser and TMDB/marker client.

``infuse`` parser mode follows regular-expression literals and request fields
observable in Infuse 8.5.1 (build 5726).  It is a clean-room compatibility
implementation, not Infuse source code, and its private result ranking cannot be
proven bit-for-bit identical.  ``extended`` mode keeps broader community naming
rules (including Chinese season/episode forms).

Examples:
    python3 infuse_tmdb_matcher.py "Movies/Inception (2010).mkv"
    python3 infuse_tmdb_matcher.py -f "Inception.2010.2160p.mkv"
    python3 infuse_tmdb_matcher.py "TV/Example Show/Season 2/07 Episode.mkv"
    python3 infuse_tmdb_matcher.py --parse-only "/media/library"
    python3 infuse_tmdb_matcher.py --json --recursive "/media/library"
    python3 infuse_tmdb_matcher.py --image-config --json
    python3 infuse_tmdb_matcher.py --movie-details 27205 --download-artwork art
    python3 infuse_tmdb_matcher.py --tv-details 119051 --json
    python3 infuse_tmdb_matcher.py --season-details 119051 2 --json
    python3 infuse_tmdb_matcher.py --markers --tmdb-id 119051 --season 1 --episode 1
"""

from __future__ import annotations

import argparse
import dataclasses
import difflib
import json
import os
import re
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePath
from typing import Any, Iterable, Iterator, Literal, Optional


DEFAULT_API_KEY = ""
TMDB_API_ROOT = "https://api.themoviedb.org/3"
THEINTRODB_API_ROOT = "https://api.theintrodb.org/v3"
INTRODB_APP_API_ROOT = "https://api.introdb.app"

VIDEO_EXTENSIONS = {
    ".3gp", ".asf", ".avi", ".divx", ".dv", ".f4v", ".flv", ".iso",
    ".m2ts", ".m4v", ".mkv", ".mov", ".mp4", ".mpeg", ".mpg", ".mts",
    ".ogm", ".ogv", ".rm", ".rmvb", ".strm", ".ts", ".vob", ".webm",
    ".wmv",
}

# Generic library/container folder names should never outrank a real title.
# This is intentionally small and language-agnostic enough for common layouts.
GENERIC_FOLDER_NAMES = {
    "movies", "films", "cinema", "videos", "mediafiles",
    "tv", "tvshows", "shows", "anime",
    "电影", "影片", "影视", "电视剧", "剧集", "动漫", "媒体库",
}

SEPARATOR_CLASS = r"[.\s_\-]"
BOUNDARY_LEFT = r"(?:^|[.\s_\-\(\[])"
BOUNDARY_RIGHT = r"(?=$|[.\s_\-\)\]])"

# Regex literals recovered from the Infuse 8.5.1 binary are expressed with
# this separator set.  Keep this compatibility block deliberately narrow;
# broader naming conventions belong to ``extended`` mode below.
INFUSE_SEPARATOR = r"[.\s_\-]"
INFUSE_TITLE_SEPARATORS = r"[.\s_\-\(\[]"
INFUSE_RIGHT_BOUNDARY = r"(?=$|[.\s_\-\)\]])"

INFUSE_EPISODE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "TitleParser_Title",
        re.compile(
            rf"(?i)^(.+?){INFUSE_SEPARATOR}?s(?:e)?{INFUSE_SEPARATOR}*0*(\d+)"
            rf"{INFUSE_SEPARATOR}*e(?:p)?{INFUSE_SEPARATOR}*0*(\d+).*$"
        ),
    ),
    (
        "TitleParser_Title_1x02",
        re.compile(rf"(?i)^(.+?){INFUSE_SEPARATOR}?(\d{{1,2}})x(\d{{2,3}}).*$"),
    ),
    (
        "TitleParser_NoTitle",
        re.compile(
            rf"(?i)^s(?:e)?{INFUSE_SEPARATOR}*0*(\d+)"
            rf"{INFUSE_SEPARATOR}*e(?:p)?{INFUSE_SEPARATOR}*0*(\d+).*$"
        ),
    ),
    (
        "TitleParser_NoTitle_1x02",
        re.compile(r"(?i)^(\d{1,2})x(\d{2,3}).*$"),
    ),
)

INFUSE_ITUNES_SEASON_EPISODE_RE = re.compile(
    rf"(?i)^0*(\d{{1,2}})-0*(\d{{1,3}}){INFUSE_SEPARATOR}+.*$"
)
INFUSE_ITUNES_EPISODE_RE = re.compile(
    rf"(?i)^0*(\d{{1,3}}){INFUSE_SEPARATOR}+.*$"
)
INFUSE_SEASON_FOLDER_RES: tuple[re.Pattern[str], ...] = (
    re.compile(rf"(?i)^s(?:e)?{INFUSE_SEPARATOR}?0*(\d+)$"),
    re.compile(r"(?i)^specials$"),
)

# Ordered title cut points visible in FCTitleParserHelper/TitleParsingRegExp.
# Infuse stops treating the suffix as a title once one of these tokens starts.
INFUSE_RELEASE_TAGS: tuple[str, ...] = (
    r"(?<=\d{4}[.\s_\-\(\[])(?:German|English|Italian|Spanish|French|Russian|Eng|Ita|Fra|Spa|Ger|Rus)",
    r"\(The\)",
    r"DC",
    r"(?:Extended|Full)?[.\s_\-\(\[]?Collectors?[.\s_\-\(\[]?Cut",
    r"Remastered",
    r"Internal",
    r"limited",
    r"Proper",
    r"(?:720|1080|480|2160)[pi]",
    r"(?:720|1080|480|2160)",
    r"U?F?HD[+B]?",
    r"full[.\s_\-\(\[]?hd",
    r"AC[.\s_\-\(\[]?3",
    r"DVD[.\s_\-\(\[]?Rip",
    r"BD[.\s_\-\(\[]?Rip",
    r"[xhi]26[345]",
    r"mpeg[.\s_\-\(\[]?[124]?",
    r"Blu[.\s_\-\(\[]?Ray",
    r"DVD",
    r"TS",
    r"TC",
    r"TeleSynch",
    r"tvrip",
    r"SATRip",
    r"CamRip",
    r"HDTVRip",
    r"BRRip",
    r"PDTV",
    r"SCR",
    r"divx",
    r"xvid",
    r"\d*[.\s_\-\(\[]?[km]bps?",
    r"dts",
    r"aac",
    r"HDR",
    r"HEVC",
    r"4K",
    r"dircut",
    r"\[?(?:cd|dvd|disk)[.\s_\-\(\[]?\d*\]?",
)
INFUSE_RELEASE_TAG_RE = re.compile(
    rf"(?i)(?:^|{INFUSE_TITLE_SEPARATORS})(?:" + "|".join(INFUSE_RELEASE_TAGS) + rf"){INFUSE_RIGHT_BOUNDARY}"
)
INFUSE_YEAR_RE = re.compile(rf"{INFUSE_TITLE_SEPARATORS}(?P<year>[0-9]{{4}}){INFUSE_RIGHT_BOUNDARY}")
INFUSE_ID_RE = re.compile(
    r"\{(?P<source>tmdb|imdb)-(?P<id>[a-z]*[0-9]+)\}", re.IGNORECASE
)
INFUSE_CUSTOM_EDITION_RE = re.compile(r"\{edition-(?P<edition>[^{}]+)\}", re.IGNORECASE)

# Localizable.strings values used to substitute the reSeason/reEpisode %@
# placeholders in FCSeriesTitleParser.  Keys mirror the 8.5.1 bundle locales.
INFUSE_LOCALIZED_EPISODE_WORDS: dict[str, tuple[str, str]] = {
    "ar": ("الموسم", "حلقة"),
    "bg": ("Сезон", "Епизод"),
    "ca": ("temporada", "episodi"),
    "cs": ("řada", "epizoda"),
    "da": ("sæson", "episode"),
    "de": ("staffel", "episode"),
    "el": ("κύκλος", "επεισόδιο"),
    "en": ("season", "episode"),
    "en-au": ("season", "episode"),
    "en-gb": ("season", "episode"),
    "es": ("temporada", "episodio"),
    "es-419": ("temporada", "episodio"),
    "et": ("hooaeg", "episood"),
    "eu-es": ("denboraldia", "Atala"),
    "fi": ("kausi", "jakso"),
    "fr": ("saison", "épisode"),
    "fr-ca": ("saison", "épisode"),
    "gu-in": ("શ્રેણી", "એપિસોડ"),
    "he": ("עונה", "פרק"),
    "hi": ("सीजन", "एपीसोड"),
    "hr": ("sezona", "epizoda"),
    "hu": ("évad", "epizód"),
    "it": ("stagione", "episodio"),
    "ja": ("シーズン", "エピソード"),
    "ko": ("시즌", "에피소드"),
    "lv": ("sezona", "epizode"),
    "my": ("အတွဲ", "အပိုင်း"),
    "nb": ("sesong", "episode"),
    "nl": ("seizoen", "aflevering"),
    "pl": ("sezon", "odcinek"),
    "pt": ("temporada", "episódio"),
    "pt-pt": ("temporada", "episódio"),
    "ro": ("sezon", "episod"),
    "ru": ("сезон", "эпизод"),
    "sk": ("séria", "epizóda"),
    "sl": ("sezona", "epizoda"),
    "sv": ("säsong", "avsnitt"),
    "tr": ("sezon", "bölüm"),
    "uk": ("сезон", "епізод"),
    "vi": ("mùa", "hồi"),
    "zh": ("季", "剧集"),
    "zh-cn": ("季", "剧集"),
    "zh-hans": ("季", "剧集"),
    "zh-hant": ("季", "集"),
    "zh-hk": ("季", "集"),
    "zh-tw": ("季", "集"),
}

ID_RE = re.compile(
    r"\{\s*(?P<source>tmdb|imdb)\s*[-:]\s*(?P<id>tt\d+|\d+)\s*\}",
    re.IGNORECASE,
)
YEAR_RE = re.compile(r"(?<!\d)(?P<year>18\d{2}|19\d{2}|20\d{2}|21\d{2})(?!\d)")

# Extract structural data before applying the release-name filter.  Ordered
# from the least ambiguous form to the more permissive forms.
EPISODE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "zh-number-token",
        re.compile(
            r"(?ix)(?P<title>.*?)"
            r"(?:^|[.\s_\-])第?0*(?P<season>\d{1,3})季"
            r"[.\s_\-]*第?0*(?P<episode>\d{1,4})(?:剧集|集|話|话)",
        ),
    ),
    (
        "zh-token-number",
        re.compile(
            r"(?ix)(?P<title>.*?)"
            r"(?:^|[.\s_\-])季[.\s_\-]*0*(?P<season>\d{1,3})"
            r"[.\s_\-]*(?:剧集|集)[.\s_\-]*0*(?P<episode>\d{1,4})",
        ),
    ),
    (
        "sxe",
        re.compile(
            rf"(?ix)(?P<title>.*?)"
            rf"(?:^|{SEPARATOR_CLASS})s(?:eason)?{SEPARATOR_CLASS}*0*(?P<season>\d{{1,3}})"
            rf"{SEPARATOR_CLASS}*e(?:p(?:isode)?)?{SEPARATOR_CLASS}*0*(?P<episode>\d{{1,4}})"
            rf"{BOUNDARY_RIGHT}",
        ),
    ),
    (
        "se-ep",
        re.compile(
            rf"(?ix)(?P<title>.*?)"
            rf"(?:^|{SEPARATOR_CLASS})se{SEPARATOR_CLASS}*0*(?P<season>\d{{1,3}})"
            rf"{SEPARATOR_CLASS}*ep{SEPARATOR_CLASS}*0*(?P<episode>\d{{1,4}})"
            rf"{BOUNDARY_RIGHT}",
        ),
    ),
    (
        "season-episode",
        re.compile(
            rf"(?ix)(?P<title>.*?)"
            rf"(?:^|{SEPARATOR_CLASS})season{SEPARATOR_CLASS}*0*(?P<season>\d{{1,3}})"
            rf"{SEPARATOR_CLASS}*episode{SEPARATOR_CLASS}*0*(?P<episode>\d{{1,4}})"
            rf"{BOUNDARY_RIGHT}",
        ),
    ),
    (
        "1x02",
        re.compile(
            rf"(?ix)(?P<title>.*?)"
            rf"(?:^|{SEPARATOR_CLASS})0*(?P<season>\d{{1,2}})x0*(?P<episode>\d{{2,4}})"
            rf"{BOUNDARY_RIGHT}",
        ),
    ),
)

SEASON_FOLDER_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"(?ix)^\s*(?:season|series|s|se)[.\s_\-]*0*(\d{1,3})\s*$"),
    re.compile(r"(?ix)^\s*(?:第[.\s_\-]*)?0*(\d{1,3})[.\s_\-]*季\s*$"),
    re.compile(r"(?ix)^\s*(?:specials?|extras?)\s*$"),
    re.compile(r"(?ix)^\s*(?:特别篇|特別篇|特别收录|特別收錄)\s*$"),
)

FOLDER_EPISODE_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("folder-01.02", re.compile(r"(?x)^\s*0*(?P<season>\d{1,2})[.\-_ ]+0*(?P<episode>\d{1,4})(?:[.\-_ ]+|$)")),
    ("folder-1-02", re.compile(r"(?x)^\s*0*(?P<season>\d{1,2})-0*(?P<episode>\d{1,4})(?:[.\-_ ]+|$)")),
    ("folder-episode", re.compile(r"(?ix)^\s*(?:episode|ep|e)[.\s_\-]*0*(?P<episode>\d{1,4})(?:[.\s_\-]+|$)")),
    ("folder-zh-episode", re.compile(r"(?ix)^\s*第?[.\s_\-]*0*(?P<episode>\d{1,4})[.\s_\-]*(?:剧集|集|話|话)(?:[.\s_\-]+|$)")),
    ("folder-number", re.compile(r"(?x)^\s*0*(?P<episode>\d{1,4})(?:[.\s_\-]+|$)")),
)

# Infuse-like release tags.  A match is normally a boundary where the rest of
# the release name no longer contributes to the title sent to TMDB.
RELEASE_TAGS = (
    r"(?:480|576|720|1080|1440|2160|4320)[pi]?",
    r"4k|8k|u?f?hd\+?|full[.\s_\-]*hd",
    r"hdr10\+?|hdr|sdr|dolby[.\s_\-]*vision|dovi|dv",
    r"x26[345]|h[.\s_\-]*26[345]|hevc|avc|av1|mpeg[.\s_\-]*[124]?|divx|xvid",
    r"blu[.\s_\-]*ray|b[dr][.\s_\-]*rip|remux|dvd[.\s_\-]*rip|web[.\s_\-]*(?:dl|rip)|webrip|hdtv(?:rip)?|tvrip|pdtv|satrip|camrip|telesync|telecine|hdcam|scr",
    r"aac|ac[.\s_\-]*3|eac3|ddp?\+?|truehd|atmos|dts(?:[.\s_\-]*(?:hd|ma|x))?|flac|mp3|opus",
    r"\d+(?:\.\d+)?[.\s_\-]*(?:kbps|mbps)",
    r"proper|repack|rerip|internal|limited|remastered",
    r"multi|dual[.\s_\-]*audio|dubbed|subbed|hardcoded",
    r"(?:director'?s?[.\s_\-]*cut|dircut|dc|extended[.\s_\-]*cut|collector'?s?[.\s_\-]*cut)",
    r"(?:cd|disc|disk|dvd|part|pt)[.\s_\-]*\d+",
    r"3d|(?:h|half)?sbs|(?:h|half)?(?:tab|ou)",
)
RELEASE_TAG_RE = re.compile(
    BOUNDARY_LEFT + r"(?:" + "|".join(RELEASE_TAGS) + r")" + BOUNDARY_RIGHT,
    re.IGNORECASE,
)

EDITION_RE = re.compile(
    r"(?ix)(?:^|[.\s_\-\(\[])"
    r"(?P<edition>director'?s?[.\s_\-]*cut|extended[.\s_\-]*cut|"
    r"theatrical[.\s_\-]*cut|final[.\s_\-]*cut|unrated(?:[.\s_\-]*cut)?|"
    r"uncut|special[.\s_\-]*edition|ultimate[.\s_\-]*edition|imax|remastered)"
    r"(?=$|[.\s_\-\)\]])",
)
CUSTOM_EDITION_RE = re.compile(r"\{\s*edition\s*[-:]\s*(?P<edition>[^{}]+)\}", re.I)
EXTRA_RE = re.compile(
    r"(?ix)(?:-|[.\s_])(?P<extra>behind[.\s_]*the[.\s_]*scenes|deleted|"
    r"featurette|interview|scene|short|trailer|other)$"
)


@dataclasses.dataclass(frozen=True)
class ParsedCandidate:
    kind: Literal["movie", "tv"]
    title: str
    year: Optional[int] = None
    season: Optional[int] = None
    episode: Optional[int] = None
    tmdb_id: Optional[int] = None
    imdb_id: Optional[str] = None
    edition: Optional[str] = None
    extra_type: Optional[str] = None
    source: str = "filename"
    priority: int = 0

    def identity(self) -> tuple[Any, ...]:
        return (
            self.kind,
            normalized_key(self.title),
            self.year,
            self.season,
            self.episode,
            self.tmdb_id,
            self.imdb_id,
        )


@dataclasses.dataclass
class MatchResult:
    input_path: str
    parsed: list[ParsedCandidate]
    selected: Optional[dict[str, Any]]
    alternatives: list[dict[str, Any]]
    errors: list[str]

    def to_jsonable(self) -> dict[str, Any]:
        return {
            "input": self.input_path,
            "parsed_candidates": [dataclasses.asdict(item) for item in self.parsed],
            "selected": self.selected,
            "alternatives": self.alternatives,
            "errors": self.errors,
        }


def strip_video_suffix(name: str) -> str:
    """Remove .strm plus an optional inner media extension."""
    result = name
    if result.lower().endswith(".strm"):
        result = result[:-5]
    suffix = PurePath(result).suffix.lower()
    if suffix in VIDEO_EXTENSIONS:
        result = result[: -len(suffix)]
    return result


def decode_name(value: str) -> str:
    value = urllib.parse.unquote(value)
    value = value.replace("\\/", "/")
    return unicodedata.normalize("NFC", value)


def clean_display_title(value: str) -> str:
    value = decode_name(value)
    value = re.sub(r"[._]+", " ", value)
    value = re.sub(r"\s*-\s*", " ", value)
    value = re.sub(r"[\[\]()]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" ._-–—")
    # Convert the library-style "Title, The" to "The Title".
    m = re.match(r"(?is)^(.+),\s*(the|a|an)$", value)
    if m:
        value = f"{m.group(2)} {m.group(1)}"
    return value.strip()


def normalized_key(value: str) -> str:
    value = unicodedata.normalize("NFKD", value).casefold()
    value = "".join(ch for ch in value if not unicodedata.combining(ch))
    return re.sub(r"[^\w]+", "", value, flags=re.UNICODE)


def is_generic_folder(value: str) -> bool:
    return normalized_key(clean_display_title(value)) in GENERIC_FOLDER_NAMES


def extract_ids(value: str) -> tuple[str, Optional[int], Optional[str]]:
    tmdb_id: Optional[int] = None
    imdb_id: Optional[str] = None

    def replace(match: re.Match[str]) -> str:
        nonlocal tmdb_id, imdb_id
        source = match.group("source").lower()
        identifier = match.group("id")
        if source == "tmdb" and identifier.isdigit():
            tmdb_id = int(identifier)
        elif source == "imdb":
            imdb_id = identifier.lower()
        return " "

    return ID_RE.sub(replace, value), tmdb_id, imdb_id


def extract_common(value: str) -> tuple[str, Optional[int], Optional[str], Optional[str], Optional[str]]:
    value, tmdb_id, imdb_id = extract_ids(value)
    edition: Optional[str] = None
    extra_type: Optional[str] = None

    custom = CUSTOM_EDITION_RE.search(value)
    if custom:
        edition = clean_display_title(custom.group("edition"))
        value = CUSTOM_EDITION_RE.sub(" ", value)
    else:
        edition_match = EDITION_RE.search(value)
        if edition_match:
            edition = clean_display_title(edition_match.group("edition"))

    extra = EXTRA_RE.search(value)
    if extra:
        extra_type = clean_display_title(extra.group("extra")).casefold()
        value = value[: extra.start()]

    return value, tmdb_id, imdb_id, edition, extra_type


def filtered_title(value: str) -> str:
    """Cut a release name at the first reliable release tag."""
    match = RELEASE_TAG_RE.search(value)
    if match:
        value = value[: match.start()]
    value = re.sub(r"(?i)(?:^|[.\s_\-\(\[])(?:sample)(?=$|[.\s_\-\)\]])", " ", value)
    return clean_display_title(value)


def extract_year(value: str) -> tuple[str, Optional[int]]:
    matches = list(YEAR_RE.finditer(value))
    if not matches:
        return value, None
    # A release year is usually the last year-shaped token after the title.
    match = matches[-1]
    year = int(match.group("year"))
    value = value[: match.start()] + " " + value[match.end() :]
    return value, year


def episode_from_name(value: str) -> Optional[tuple[str, int, int, str]]:
    for pattern_name, pattern in EPISODE_PATTERNS:
        match = pattern.search(value)
        if match:
            title = match.groupdict().get("title") or ""
            return title, int(match.group("season")), int(match.group("episode")), pattern_name
    return None


def season_from_folder(value: str) -> Optional[int]:
    cleaned = clean_display_title(value)
    for index, pattern in enumerate(SEASON_FOLDER_PATTERNS):
        match = pattern.match(cleaned)
        if match:
            return 0 if match.lastindex is None else int(match.group(1))
    return None


def folder_episode(value: str, folder_season: Optional[int]) -> Optional[tuple[int, int, str]]:
    for pattern_name, pattern in FOLDER_EPISODE_PATTERNS:
        match = pattern.search(value)
        if not match:
            continue
        season_text = match.groupdict().get("season")
        episode_text = match.groupdict().get("episode")
        if not episode_text:
            continue
        season = int(season_text) if season_text else folder_season
        if season is not None:
            return season, int(episode_text), pattern_name
    return None


def meaningful_parents(parents: list[str]) -> list[str]:
    """Nearest-first parent folders that can plausibly carry a title."""
    return [
        parent for parent in reversed(parents[-3:])
        if season_from_folder(parent) is None and not is_generic_folder(parent)
    ]


def path_parts(raw_path: str) -> list[str]:
    decoded = decode_name(raw_path).replace("\\", "/")
    parts = [part for part in decoded.split("/") if part and part not in {".", ".."}]
    return parts or [decoded]


def chinese_variants(value: str) -> list[str]:
    """Return Simplified/Traditional variants when opencc-python is installed."""
    try:
        from opencc import OpenCC  # type: ignore[import-not-found]
    except ImportError:
        return []

    variants: list[str] = []
    for config in ("t2s", "s2t", "s2tw", "s2hk"):
        try:
            converted = OpenCC(config).convert(value)
        except Exception:
            continue
        if converted and normalized_key(converted) != normalized_key(value):
            variants.append(converted)
    return unique_strings(variants)


def unique_strings(values: Iterable[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        key = normalized_key(value)
        if value and key and key not in seen:
            seen.add(key)
            result.append(value)
    return result


def dedupe_candidates(candidates: Iterable[ParsedCandidate]) -> list[ParsedCandidate]:
    result: list[ParsedCandidate] = []
    seen: set[tuple[Any, ...]] = set()
    for candidate in sorted(candidates, key=lambda item: item.priority, reverse=True):
        if not candidate.title and not candidate.tmdb_id and not candidate.imdb_id:
            continue
        key = candidate.identity()
        if key not in seen:
            seen.add(key)
            result.append(candidate)
    return result


def infuse_filtered_title(value: str) -> str:
    """Apply the narrow title cut points observable in Infuse 8.5.1."""
    match = INFUSE_RELEASE_TAG_RE.search(value)
    if match:
        value = value[: match.start()]
    return clean_display_title(value)


def infuse_extract_common(
    value: str,
) -> tuple[str, Optional[int], Optional[str], Optional[str], Optional[str]]:
    """Extract only the exact brace forms visible in TitleParsingRegExp."""
    tmdb_id: Optional[int] = None
    imdb_id: Optional[str] = None

    def remove_id(match: re.Match[str]) -> str:
        nonlocal tmdb_id, imdb_id
        source = match.group("source").casefold()
        identifier = match.group("id").casefold()
        if source == "tmdb" and identifier.isdigit():
            tmdb_id = int(identifier)
        elif source == "imdb":
            imdb_id = identifier
        return " "

    value = INFUSE_ID_RE.sub(remove_id, value)
    edition: Optional[str] = None
    edition_match = INFUSE_CUSTOM_EDITION_RE.search(value)
    if edition_match:
        edition = clean_display_title(edition_match.group("edition"))
        value = INFUSE_CUSTOM_EDITION_RE.sub(" ", value)
    else:
        named_edition = EDITION_RE.search(value)
        if named_edition:
            edition = clean_display_title(named_edition.group("edition"))

    extra_type: Optional[str] = None
    extra_match = EXTRA_RE.search(value)
    if extra_match:
        extra_type = clean_display_title(extra_match.group("extra")).casefold()
        value = value[: extra_match.start()]
    return value, tmdb_id, imdb_id, edition, extra_type


def infuse_extract_year(value: str) -> tuple[str, Optional[int]]:
    """Extract Infuse's separator-prefixed four-digit year token."""
    match = INFUSE_YEAR_RE.search(value)
    if not match:
        return value, None
    year = int(match.group("year"))
    return value[: match.start()] + " " + value[match.end() :], year


def infuse_episode_words(parser_language: str) -> tuple[str, str]:
    key = parser_language.replace("_", "-").casefold()
    if key in INFUSE_LOCALIZED_EPISODE_WORDS:
        return INFUSE_LOCALIZED_EPISODE_WORDS[key]
    primary = key.split("-", 1)[0]
    return INFUSE_LOCALIZED_EPISODE_WORDS.get(primary, INFUSE_LOCALIZED_EPISODE_WORDS["en"])


def infuse_episode_from_name(
    value: str,
    parser_language: str,
) -> Optional[tuple[str, int, int, str]]:
    season_word, episode_word = map(re.escape, infuse_episode_words(parser_language))
    localized = re.compile(
        rf"(?i)^(.+?){INFUSE_SEPARATOR}?{season_word}{INFUSE_SEPARATOR}?0*(\d+)"
        rf"{INFUSE_SEPARATOR}*{episode_word}{INFUSE_SEPARATOR}?0*(\d+).*$"
    )
    match = localized.match(value)
    if match:
        return match.group(1), int(match.group(2)), int(match.group(3)), "TitleParser_Title_Localized"
    for pattern_name, pattern in INFUSE_EPISODE_PATTERNS:
        match = pattern.match(value)
        if not match:
            continue
        groups = match.groups()
        if pattern_name.startswith("TitleParser_Title_") or pattern_name == "TitleParser_Title":
            return groups[0], int(groups[1]), int(groups[2]), pattern_name
        return "", int(groups[0]), int(groups[1]), pattern_name
    return None


def infuse_season_from_folder(value: str, parser_language: str = "en") -> Optional[int]:
    cleaned = strip_video_suffix(value).strip(" ._-")
    season_word, _ = infuse_episode_words(parser_language)
    localized = re.compile(
        rf"(?i)^{re.escape(season_word)}{INFUSE_SEPARATOR}*0*(\d+)$"
    )
    localized_match = localized.match(cleaned)
    if localized_match:
        return int(localized_match.group(1))
    for index, pattern in enumerate(INFUSE_SEASON_FOLDER_RES):
        match = pattern.match(cleaned)
        if match:
            return 0 if index == len(INFUSE_SEASON_FOLDER_RES) - 1 else int(match.group(1))
    return None


def infuse_parent_titles(parents: list[str], parser_language: str) -> list[tuple[str, str]]:
    """Nearest-first parent title candidates, including season-parent layouts."""
    result: list[tuple[str, str]] = []
    for distance, parent in enumerate(reversed(parents[-3:]), start=1):
        if infuse_season_from_folder(parent, parser_language) is not None:
            continue
        if clean_display_title(parent):
            result.append((parent, f"parent:{distance}"))
    return result


def parse_media_path_infuse(
    raw_path: str,
    forced_kind: Optional[Literal["movie", "tv"]] = None,
    parser_language: str = "en",
) -> list[ParsedCandidate]:
    """Best-effort Infuse 8.5.1 compatible parser path, without network I/O."""
    parts = path_parts(raw_path)
    filename = strip_video_suffix(parts[-1])
    parents = parts[:-1]
    first_parent = parents[-1] if parents else ""

    raw_name, tmdb_id, imdb_id, edition, extra_type = infuse_extract_common(filename)
    episode_info = infuse_episode_from_name(raw_name, parser_language)
    parent_season = infuse_season_from_folder(first_parent, parser_language) if first_parent else None

    # The iTunes layouts embedded in FCSeriesTitleParser are consulted only
    # after the explicit SxxEyy/1x02 forms fail.
    itunes_source: Optional[str] = None
    if episode_info is None:
        match = INFUSE_ITUNES_SEASON_EPISODE_RE.match(raw_name)
        if match:
            episode_info = ("", int(match.group(1)), int(match.group(2)), "iTunesEpisodeAndSeason")
            itunes_source = "iTunesEpisodeAndSeason"
        elif parent_season is not None:
            _, localized_episode_word = infuse_episode_words(parser_language)
            localized_prefix = re.compile(
                rf"(?i)^{re.escape(localized_episode_word)}{INFUSE_SEPARATOR}?0*(\d{{1,3}})"
                rf"{INFUSE_SEPARATOR}+.*$"
            )
            localized_suffix = re.compile(
                rf"(?i)^0*(\d{{1,3}}){INFUSE_SEPARATOR}*{re.escape(localized_episode_word)}"
                rf"(?:{INFUSE_SEPARATOR}+.*)?$"
            )
            match = (
                localized_prefix.match(raw_name)
                or localized_suffix.match(raw_name)
                or INFUSE_ITUNES_EPISODE_RE.match(raw_name)
            )
            if match:
                episode_info = ("", parent_season, int(match.group(1)), "iTunesEpisodeOnly")
                itunes_source = "iTunesEpisodeOnly"

    looks_tv = episode_info is not None
    allow_tv = forced_kind in (None, "tv")
    allow_movie = forced_kind in (None, "movie")
    candidates: list[ParsedCandidate] = []

    if allow_tv and episode_info:
        raw_title, season, episode, pattern_name = episode_info
        title_with_year = infuse_filtered_title(raw_title)
        title_without_year, year = infuse_extract_year(title_with_year)
        direct_title = clean_display_title(title_without_year)
        if direct_title:
            candidates.append(
                ParsedCandidate(
                    "tv", direct_title, year, season, episode, tmdb_id, imdb_id,
                    edition, extra_type, f"filename:{pattern_name}", 100,
                )
            )

        # FCSeriesTitleParser explicitly sorts parent-derived variants.  The
        # nearest non-season folder is therefore a candidate even when the
        # filename itself contains a show title.
        for offset, (parent_value, source) in enumerate(infuse_parent_titles(parents, parser_language)):
            parent_raw, parent_tmdb, parent_imdb, _, _ = infuse_extract_common(parent_value)
            parent_filtered = infuse_filtered_title(parent_raw)
            parent_year_text, parent_year = infuse_extract_year(parent_filtered)
            parent_title = clean_display_title(parent_year_text)
            candidates.append(
                ParsedCandidate(
                    "tv", parent_title, parent_year or year, season, episode,
                    tmdb_id or parent_tmdb, imdb_id or parent_imdb, edition, extra_type,
                    f"{source}:{itunes_source or pattern_name}", 92 - offset,
                )
            )

    if allow_tv and forced_kind == "tv" and not looks_tv:
        title_with_year = infuse_filtered_title(raw_name)
        title_without_year, year = infuse_extract_year(title_with_year)
        title = clean_display_title(title_without_year)
        if title:
            candidates.append(
                ParsedCandidate(
                    "tv", title, year, tmdb_id=tmdb_id, imdb_id=imdb_id,
                    edition=edition, extra_type=extra_type, source="forced-tv", priority=70,
                )
            )

    if allow_movie and (forced_kind == "movie" or not looks_tv):
        title_with_year = infuse_filtered_title(raw_name)
        title_without_year, year = infuse_extract_year(title_with_year)
        title = clean_display_title(title_without_year)
        if title or tmdb_id or imdb_id:
            candidates.append(
                ParsedCandidate(
                    "movie", title, year, tmdb_id=tmdb_id, imdb_id=imdb_id,
                    edition=edition, extra_type=extra_type, source="filename", priority=90 if year else 80,
                )
            )

        # Infuse also forms a first-parent movie variant.  Do not apply the
        # extended parser's generic-folder blacklist in compatibility mode.
        if first_parent:
            parent_raw, parent_tmdb, parent_imdb, parent_edition, _ = infuse_extract_common(first_parent)
            parent_filtered = infuse_filtered_title(parent_raw)
            parent_without_year, parent_year = infuse_extract_year(parent_filtered)
            parent_title = clean_display_title(parent_without_year)
            if parent_title:
                candidates.append(
                    ParsedCandidate(
                        "movie", parent_title, parent_year,
                        tmdb_id=tmdb_id or parent_tmdb, imdb_id=imdb_id or parent_imdb,
                        edition=edition or parent_edition, extra_type=extra_type,
                        source="parent:1", priority=72 if parent_year else 62,
                    )
                )

    return dedupe_candidates(candidates)


def parse_media_path_extended(
    raw_path: str,
    forced_kind: Optional[Literal["movie", "tv"]] = None,
) -> list[ParsedCandidate]:
    """Generate broader movie/TV candidates from a path without network I/O."""
    parts = path_parts(raw_path)
    filename = strip_video_suffix(parts[-1])
    parents = parts[:-1]
    first_parent = parents[-1] if parents else ""
    second_parent = parents[-2] if len(parents) >= 2 else ""

    raw_name, tmdb_id, imdb_id, edition, extra_type = extract_common(filename)
    direct_episode = episode_from_name(raw_name)
    parent_season = season_from_folder(first_parent) if first_parent else None
    folder_ep = folder_episode(raw_name, parent_season)
    looks_tv = direct_episode is not None or folder_ep is not None

    candidates: list[ParsedCandidate] = []
    allow_tv = forced_kind in (None, "tv")
    allow_movie = forced_kind in (None, "movie")

    if allow_tv and direct_episode:
        title_raw, season, episode, pattern = direct_episode
        title = filtered_title(title_raw)
        title_without_year, year = extract_year(title)
        title = clean_display_title(title_without_year)
        parent_options = meaningful_parents(parents)
        if not title and parent_options:
            title = filtered_title(parent_options[0])
        candidates.append(
            ParsedCandidate(
                "tv", title, year, season, episode, tmdb_id, imdb_id,
                edition, extra_type, f"filename:{pattern}", 100,
            )
        )

        # If an episode name begins with SxxExx, the show title is carried by a
        # parent folder.  Try the nearest non-season folder first.
        for offset, parent in enumerate(parent_options):
            parent_title, parent_year = extract_year(filtered_title(parent))
            parent_title = clean_display_title(parent_title)
            if parent_title:
                candidates.append(
                    ParsedCandidate(
                        "tv", parent_title, parent_year or year, season, episode,
                        tmdb_id, imdb_id, edition, extra_type,
                        f"parent:{offset + 1}", 92 - offset,
                    )
                )

    if allow_tv and folder_ep:
        season, episode, pattern = folder_ep
        parent_options = meaningful_parents(parents)
        for offset, series_folder in enumerate(parent_options):
            title_raw, folder_tmdb, folder_imdb, _, _ = extract_common(series_folder)
            title_no_year, year = extract_year(filtered_title(title_raw))
            title = clean_display_title(title_no_year)
            candidates.append(
                ParsedCandidate(
                    "tv", title, year, season, episode,
                    tmdb_id or folder_tmdb, imdb_id or folder_imdb,
                    edition, extra_type, f"path:{pattern}:parent-{offset + 1}", 97 - offset,
                )
            )

    # With --type tv, a name can still be a show title even if no episode token
    # is present.  Without --type, only construct this fallback after TV evidence.
    if allow_tv and (forced_kind == "tv" or looks_tv):
        parent_options = meaningful_parents(parents)
        base = direct_episode[0] if direct_episode else ((parent_options or [raw_name])[0])
        base_title, base_year = extract_year(filtered_title(base))
        base_title = clean_display_title(base_title)
        if base_title:
            candidates.append(
                ParsedCandidate(
                    "tv", base_title, base_year,
                    direct_episode[1] if direct_episode else (folder_ep[0] if folder_ep else None),
                    direct_episode[2] if direct_episode else (folder_ep[1] if folder_ep else None),
                    tmdb_id, imdb_id, edition, extra_type, "tv-fallback", 70,
                )
            )

    if allow_movie and (forced_kind == "movie" or not looks_tv):
        cleaned = filtered_title(raw_name)
        without_year, year = extract_year(cleaned)
        title = clean_display_title(without_year)
        candidates.append(
            ParsedCandidate(
                "movie", title, year, None, None, tmdb_id, imdb_id,
                edition, extra_type, "filename", 90 if year else 80,
            )
        )

        # A movie folder may be cleaner than a generic filename such as
        # "movie.mkv" or can carry the year/ID omitted by the file.
        if first_parent and not is_generic_folder(first_parent):
            parent_raw, parent_tmdb, parent_imdb, parent_edition, _ = extract_common(first_parent)
            parent_clean, parent_year = extract_year(filtered_title(parent_raw))
            parent_title = clean_display_title(parent_clean)
            if parent_title:
                candidates.append(
                    ParsedCandidate(
                        "movie", parent_title, parent_year,
                        tmdb_id=tmdb_id or parent_tmdb,
                        imdb_id=imdb_id or parent_imdb,
                        edition=edition or parent_edition,
                        extra_type=extra_type,
                        source="parent:1", priority=72 if parent_year else 62,
                    )
                )

    # Infuse ships OpenCC and tries multiple Chinese writing-system variants.
    expanded = list(candidates)
    for candidate in candidates:
        for index, title_variant in enumerate(chinese_variants(candidate.title)):
            expanded.append(dataclasses.replace(
                candidate,
                title=title_variant,
                source=f"{candidate.source}:zh-variant-{index + 1}",
                priority=candidate.priority - index - 2,
            ))

    return dedupe_candidates(expanded)


def parse_media_path(
    raw_path: str,
    forced_kind: Optional[Literal["movie", "tv"]] = None,
    parser_mode: Literal["infuse", "extended"] = "infuse",
    parser_language: str = "en",
) -> list[ParsedCandidate]:
    if parser_mode == "extended":
        return parse_media_path_extended(raw_path, forced_kind)
    return parse_media_path_infuse(raw_path, forced_kind, parser_language)


class TMDBError(RuntimeError):
    pass


class TMDBClient:
    def __init__(
        self,
        api_key: str,
        language: str = "zh-CN",
        timeout: float = 10.0,
        thumbnail_language: Optional[str] = None,
    ) -> None:
        self.api_key = api_key
        self.language = language
        self.thumbnail_language = thumbnail_language or language
        self.timeout = timeout
        self._last_request_at = 0.0
        self._configuration: Optional[dict[str, Any]] = None

    def get(self, endpoint: str, **params: Any) -> dict[str, Any]:
        query = {"api_key": self.api_key, **params}
        query = {key: value for key, value in query.items() if value is not None}
        url = f"{TMDB_API_ROOT}{endpoint}?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(
            url,
            headers={"Accept": "application/json", "User-Agent": "infuse-tmdb-matcher/1.0"},
        )

        # Small spacing makes recursive scans friendlier to the public API.
        elapsed = time.monotonic() - self._last_request_at
        if elapsed < 0.04:
            time.sleep(0.04 - elapsed)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read().decode("utf-8")
                self._last_request_at = time.monotonic()
                return json.loads(payload)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            message = body
            try:
                message = json.loads(body).get("status_message", body)
            except json.JSONDecodeError:
                pass
            raise TMDBError(f"TMDB HTTP {exc.code}: {message}") from exc
        except urllib.error.URLError as exc:
            raise TMDBError(f"TMDB connection failed: {exc.reason}") from exc
        except json.JSONDecodeError as exc:
            raise TMDBError("TMDB returned invalid JSON") from exc

    def search(self, candidate: ParsedCandidate) -> list[dict[str, Any]]:
        if candidate.tmdb_id:
            endpoint = f"/{'tv' if candidate.kind == 'tv' else 'movie'}/{candidate.tmdb_id}"
            try:
                return [self.get(endpoint, language=self.language)]
            except TMDBError as exc:
                if "HTTP 404" in str(exc):
                    return []
                raise

        if candidate.imdb_id:
            found = self.get(
                f"/find/{candidate.imdb_id}",
                external_source="imdb_id",
                language=self.language,
            )
            key = "tv_results" if candidate.kind == "tv" else "movie_results"
            exact = list(found.get(key) or [])
            if exact:
                return exact

        params: dict[str, Any] = {
            "query": candidate.title,
            "language": self.language,
            "include_adult": "false",
            "page": 1,
        }
        if candidate.year:
            params["first_air_date_year" if candidate.kind == "tv" else "primary_release_year"] = candidate.year
        payload = self.get(f"/search/{'tv' if candidate.kind == 'tv' else 'movie'}", **params)
        return list(payload.get("results") or [])

    def episode_details(self, tv_id: int, season: int, episode: int) -> Optional[dict[str, Any]]:
        try:
            return self.get(
                f"/tv/{tv_id}/season/{season}/episode/{episode}",
                language=self.language,
            )
        except TMDBError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise

    def episode_full_details(self, tv_id: int, season: int, episode: int) -> dict[str, Any]:
        return self.get(
            f"/tv/{tv_id}/season/{season}/episode/{episode}",
            language=self.language,
            append_to_response="credits,external_ids,images,translations",
            include_image_language=self.include_image_language(),
        )

    def configuration(self, refresh: bool = False) -> dict[str, Any]:
        if self._configuration is None or refresh:
            self._configuration = self.get("/configuration")
        return self._configuration

    def image_configuration(self) -> dict[str, Any]:
        images = self.configuration().get("images")
        if not isinstance(images, dict):
            raise TMDBError("TMDB configuration has no images object")
        return images

    def include_image_language(self) -> str:
        # TMDB image language uses ISO-639-1, unlike metadata's xx-YY locale.
        requested = self.thumbnail_language.split("-", 1)[0].strip().lower()
        values = [requested, "en", "null"]
        return ",".join(dict.fromkeys(value for value in values if value))

    def movie_details(self, movie_id: int) -> dict[str, Any]:
        return self.get(
            f"/movie/{movie_id}",
            language=self.language,
            append_to_response="casts,releases,images,alternative_titles,translations",
            include_image_language=self.include_image_language(),
        )

    def tv_details(self, series_id: int) -> dict[str, Any]:
        return self.get(
            f"/tv/{series_id}",
            language=self.language,
            append_to_response="credits,content_ratings,external_ids,images,translations,alternative_titles",
            include_image_language=self.include_image_language(),
        )

    def season_details(self, series_id: int, season_number: int) -> dict[str, Any]:
        return self.get(
            f"/tv/{series_id}/season/{season_number}",
            language=self.language,
            append_to_response="credits,external_ids,images,translations",
            include_image_language=self.include_image_language(),
        )

    @staticmethod
    def _image_size_key(kind: str) -> str:
        mapping = {
            "backdrop": "backdrop_sizes",
            "logo": "logo_sizes",
            "poster": "poster_sizes",
            "profile": "profile_sizes",
            "still": "still_sizes",
        }
        try:
            return mapping[kind]
        except KeyError as exc:
            raise TMDBError(f"Unsupported TMDB image kind: {kind}") from exc

    def image_url(self, image_path: str, kind: str, size: str = "original") -> str:
        images = self.image_configuration()
        sizes = images.get(self._image_size_key(kind)) or []
        if size not in sizes:
            raise TMDBError(
                f"Unsupported {kind} size {size!r}; supported: {', '.join(map(str, sizes))}"
            )
        base_url = str(images.get("secure_base_url") or images.get("base_url") or "")
        if not base_url:
            raise TMDBError("TMDB configuration has no image base URL")
        return f"{base_url.rstrip('/')}/{size}/{str(image_path).lstrip('/')}"

    def download_image(
        self,
        image_path: str,
        kind: str,
        output_dir: Path,
        *,
        size: str = "original",
        name_prefix: str = "tmdb",
    ) -> Path:
        url = self.image_url(image_path, kind, size)
        suffix = PurePath(urllib.parse.urlparse(image_path).path).suffix or ".jpg"
        filename = f"{safe_filename(name_prefix)}_{kind}_{size}{suffix}"
        output_dir.mkdir(parents=True, exist_ok=True)
        destination = output_dir / filename
        request = urllib.request.Request(
            url,
            headers={"Accept": "image/*", "User-Agent": "infuse-tmdb-matcher/2.0"},
        )
        temporary_name: Optional[str] = None
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                with tempfile.NamedTemporaryFile(
                    mode="wb", prefix=f".{filename}.", dir=output_dir, delete=False
                ) as temporary:
                    temporary_name = temporary.name
                    while True:
                        chunk = response.read(1024 * 256)
                        if not chunk:
                            break
                        temporary.write(chunk)
            os.replace(temporary_name, destination)
            temporary_name = None
            return destination
        except (urllib.error.HTTPError, urllib.error.URLError) as exc:
            raise TMDBError(f"Image download failed for {url}: {exc}") from exc
        finally:
            if temporary_name:
                try:
                    os.unlink(temporary_name)
                except FileNotFoundError:
                    pass


def safe_filename(value: str) -> str:
    value = unicodedata.normalize("NFC", value)
    value = re.sub(r"[^\w.-]+", "_", value, flags=re.UNICODE).strip("._")
    return value[:120] or "tmdb"


def image_configuration_summary(client: TMDBClient) -> dict[str, Any]:
    images = client.image_configuration()
    return {
        "base_url": images.get("base_url"),
        "secure_base_url": images.get("secure_base_url"),
        "backdrop_sizes": images.get("backdrop_sizes") or [],
        "logo_sizes": images.get("logo_sizes") or [],
        "poster_sizes": images.get("poster_sizes") or [],
        "profile_sizes": images.get("profile_sizes") or [],
        "still_sizes": images.get("still_sizes") or [],
    }


def artwork_payload(
    client: TMDBClient,
    details: dict[str, Any],
    *,
    output_dir: Optional[Path] = None,
    size: str = "original",
    name_prefix: Optional[str] = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    prefix = name_prefix or f"tmdb_{details.get('id', 'unknown')}"
    fields = [("poster", "poster_path"), ("backdrop", "backdrop_path")]
    if details.get("still_path"):
        fields.append(("still", "still_path"))
    for kind, field in fields:
        image_path = details.get(field)
        if not image_path:
            continue
        result[kind] = {
            "path": image_path,
            "original_url": client.image_url(str(image_path), kind, size),
        }
        if output_dir is not None:
            downloaded = client.download_image(
                str(image_path), kind, output_dir, size=size, name_prefix=prefix
            )
            result[kind]["downloaded_to"] = str(downloaded.resolve())
    return result


class MarkerError(RuntimeError):
    pass


def marker_json_get(
    root: str,
    endpoint: str,
    params: dict[str, Any],
    timeout: float,
    api_key: Optional[str] = None,
) -> Optional[dict[str, Any]]:
    query = urllib.parse.urlencode(
        {key: value for key, value in params.items() if value is not None}
    )
    url = f"{root.rstrip('/')}/{endpoint.lstrip('/')}?{query}"
    headers = {"Accept": "application/json", "User-Agent": "infuse-tmdb-matcher/2.0"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key.strip()}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        body = exc.read().decode("utf-8", "replace")
        raise MarkerError(f"{urllib.parse.urlparse(root).netloc} HTTP {exc.code}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise MarkerError(f"{urllib.parse.urlparse(root).netloc} connection failed: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise MarkerError(f"{urllib.parse.urlparse(root).netloc} returned invalid JSON") from exc


def normalized_segment(
    provider: str,
    segment_type: str,
    value: Any,
) -> Optional[dict[str, Any]]:
    if not isinstance(value, dict):
        return None
    start_ms = value.get("start_ms")
    end_ms = value.get("end_ms")
    if start_ms is None and value.get("start_sec") is not None:
        start_ms = round(float(value["start_sec"]) * 1000)
    if end_ms is None and value.get("end_sec") is not None:
        end_ms = round(float(value["end_sec"]) * 1000)
    if start_ms is None and end_ms is None:
        return None
    return {
        "type": segment_type,
        "start_ms": int(start_ms) if start_ms is not None else None,
        "end_ms": int(end_ms) if end_ms is not None else None,
        "provider": provider,
        **({"confidence": value["confidence"]} if value.get("confidence") is not None else {}),
        **(
            {"submission_count": value["submission_count"]}
            if value.get("submission_count") is not None else {}
        ),
    }


def theintrodb_markers(
    *,
    tmdb_id: Optional[int],
    imdb_id: Optional[str],
    media_type: Literal["movie", "tv"],
    season: Optional[int],
    episode: Optional[int],
    duration_ms: Optional[int],
    timeout: float,
    api_key: Optional[str],
) -> list[dict[str, Any]]:
    if not tmdb_id and not imdb_id:
        return []
    if media_type == "tv" and (season is None or episode is None):
        raise MarkerError("TheIntroDB TV lookup requires season and episode")
    payload = marker_json_get(
        THEINTRODB_API_ROOT,
        "/media",
        {
            "tmdb_id": tmdb_id,
            "imdb_id": imdb_id if not tmdb_id else None,
            "season": season if media_type == "tv" else None,
            "episode": episode if media_type == "tv" else None,
            "duration_ms": duration_ms,
        },
        timeout,
        api_key,
    )
    if not payload:
        return []
    segments: list[dict[str, Any]] = []
    for response_key, segment_type in (
        ("intro", "intro"),
        ("recap", "recap"),
        ("credits", "outro"),
        ("preview", "preview"),
    ):
        values = payload.get(response_key) or []
        if isinstance(values, dict):
            values = [values]
        for value in values:
            segment = normalized_segment("theintrodb.org", segment_type, value)
            if segment:
                segments.append(segment)
    return segments


def introdb_app_markers(
    *,
    imdb_id: Optional[str],
    season: Optional[int],
    episode: Optional[int],
    timeout: float,
) -> list[dict[str, Any]]:
    if not imdb_id:
        return []
    if season is None or episode is None:
        raise MarkerError("IntroDB.app lookup requires season and episode")
    payload = marker_json_get(
        INTRODB_APP_API_ROOT,
        "/segments",
        {"imdb_id": imdb_id, "season": season, "episode": episode},
        timeout,
    )
    if not payload:
        return []
    segments: list[dict[str, Any]] = []
    for response_key, segment_type in (("intro", "intro"), ("recap", "recap"), ("outro", "outro")):
        segment = normalized_segment("introdb.app", segment_type, payload.get(response_key))
        if segment:
            segments.append(segment)
    return segments


def fetch_markers(
    *,
    tmdb_id: Optional[int],
    imdb_id: Optional[str],
    media_type: Literal["movie", "tv"],
    season: Optional[int],
    episode: Optional[int],
    duration_ms: Optional[int],
    timeout: float,
    provider: Literal["auto", "theintrodb", "introdb"],
    api_key: Optional[str] = None,
) -> dict[str, Any]:
    """Fetch markers with TheIntroDB -> IntroDB.app field-level fallback."""
    attempted: list[str] = []
    errors: list[str] = []
    collected: list[dict[str, Any]] = []

    if provider in ("auto", "theintrodb"):
        attempted.append("theintrodb.org")
        try:
            collected.extend(
                theintrodb_markers(
                    tmdb_id=tmdb_id,
                    imdb_id=imdb_id,
                    media_type=media_type,
                    season=season,
                    episode=episode,
                    duration_ms=duration_ms,
                    timeout=timeout,
                    api_key=api_key,
                )
            )
        except MarkerError as exc:
            errors.append(str(exc))

    # IntroDB.app is an episode-only backup.  In auto mode, query it when the
    # primary returned nothing or when it can fill intro/recap/outro gaps.
    if provider in ("auto", "introdb") and media_type == "tv":
        wanted_types = {"intro", "recap", "outro"}
        existing_types = {str(item["type"]) for item in collected}
        if provider == "introdb" or wanted_types - existing_types:
            attempted.append("introdb.app")
            try:
                fallback = introdb_app_markers(
                    imdb_id=imdb_id, season=season, episode=episode, timeout=timeout
                )
                for segment in fallback:
                    if segment["type"] not in existing_types:
                        collected.append(segment)
                        existing_types.add(str(segment["type"]))
            except MarkerError as exc:
                errors.append(str(exc))

    collected.sort(key=lambda item: (item.get("start_ms") is None, item.get("start_ms") or 0))
    return {
        "request": {
            "media_type": media_type,
            "tmdb_id": tmdb_id,
            "imdb_id": imdb_id,
            "season": season,
            "episode": episode,
            "duration_ms": duration_ms,
        },
        "attempted_providers": attempted,
        "segments": collected,
        "errors": errors,
    }


def similarity(left: str, right: str) -> float:
    left_key, right_key = normalized_key(left), normalized_key(right)
    if not left_key or not right_key:
        return 0.0
    if left_key == right_key:
        return 1.0
    ratio = difflib.SequenceMatcher(None, left_key, right_key).ratio()
    if left_key in right_key or right_key in left_key:
        ratio = max(ratio, min(len(left_key), len(right_key)) / max(len(left_key), len(right_key)))
    return ratio


def result_names(item: dict[str, Any], kind: str) -> list[str]:
    if kind == "tv":
        return [str(item.get("name") or ""), str(item.get("original_name") or "")]
    return [str(item.get("title") or ""), str(item.get("original_title") or "")]


def result_year(item: dict[str, Any], kind: str) -> Optional[int]:
    value = item.get("first_air_date" if kind == "tv" else "release_date") or ""
    match = re.match(r"(\d{4})", str(value))
    return int(match.group(1)) if match else None


def score_result(candidate: ParsedCandidate, item: dict[str, Any]) -> float:
    names = result_names(item, candidate.kind)
    score = max((similarity(candidate.title, name) for name in names), default=0.0) * 70.0
    year = result_year(item, candidate.kind)
    if candidate.year and year:
        delta = abs(candidate.year - year)
        score += 20.0 if delta == 0 else (8.0 if delta == 1 else -min(20.0, delta * 4.0))
    if candidate.tmdb_id and item.get("id") == candidate.tmdb_id:
        score += 100.0
    if candidate.imdb_id:
        score += 40.0
    popularity = float(item.get("popularity") or 0.0)
    vote_count = int(item.get("vote_count") or 0)
    score += min(5.0, popularity / 50.0)
    score += min(5.0, vote_count / 1000.0)
    score += candidate.priority / 20.0
    return round(score, 3)


def simplify_result(
    client: TMDBClient,
    candidate: ParsedCandidate,
    item: dict[str, Any],
    score: float,
    episode_details: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    title = item.get("name") if candidate.kind == "tv" else item.get("title")
    original_title = item.get("original_name") if candidate.kind == "tv" else item.get("original_title")
    poster_path = item.get("poster_path")
    result: dict[str, Any] = {
        "media_type": candidate.kind,
        "tmdb_id": item.get("id"),
        "title": title,
        "original_title": original_title,
        "year": result_year(item, candidate.kind),
        "score": score,
        "matched_query": candidate.title,
        "query_source": candidate.source,
        "overview": item.get("overview"),
        "poster_url": client.image_url(str(poster_path), "poster", "w500") if poster_path else None,
    }
    if candidate.kind == "tv":
        result.update({"season": candidate.season, "episode": candidate.episode})
        if episode_details:
            result["episode_details"] = {
                "tmdb_id": episode_details.get("id"),
                "name": episode_details.get("name"),
                "air_date": episode_details.get("air_date"),
                "overview": episode_details.get("overview"),
                "runtime": episode_details.get("runtime"),
                "still_url": (
                    client.image_url(str(episode_details.get("still_path")), "still", "w300")
                    if episode_details.get("still_path") else None
                ),
            }
    return result


def match_path(
    raw_path: str,
    client: TMDBClient,
    forced_kind: Optional[Literal["movie", "tv"]] = None,
    parser_mode: Literal["infuse", "extended"] = "infuse",
    parser_language: str = "en",
    max_candidates: int = 6,
    max_results_per_query: int = 5,
) -> MatchResult:
    candidates = parse_media_path(raw_path, forced_kind, parser_mode, parser_language)
    errors: list[str] = []
    collected: dict[tuple[str, int, Optional[int], Optional[int]], dict[str, Any]] = {}

    for candidate in candidates[:max_candidates]:
        try:
            results = client.search(candidate)
        except TMDBError as exc:
            errors.append(f"{candidate.source}: {exc}")
            continue

        for item in results[:max_results_per_query]:
            identifier = item.get("id")
            if not isinstance(identifier, int):
                continue
            episode_details: Optional[dict[str, Any]] = None
            if candidate.kind == "tv" and candidate.season is not None and candidate.episode is not None:
                try:
                    episode_details = client.episode_details(identifier, candidate.season, candidate.episode)
                except TMDBError as exc:
                    errors.append(f"episode validation for TMDB {identifier}: {exc}")
                    continue
                if episode_details is None:
                    # A similarly named show without the requested episode is
                    # much less useful than the next search result.
                    continue

            score = score_result(candidate, item)
            if episode_details is not None:
                score += 25.0
            simplified = simplify_result(client, candidate, item, round(score, 3), episode_details)
            key = (candidate.kind, identifier, candidate.season, candidate.episode)
            previous = collected.get(key)
            if previous is None or simplified["score"] > previous["score"]:
                collected[key] = simplified

    ranked = sorted(collected.values(), key=lambda item: item["score"], reverse=True)
    return MatchResult(raw_path, candidates, ranked[0] if ranked else None, ranked[1:6], errors)


def discover_inputs(values: list[str], recursive: bool) -> Iterator[str]:
    for value in values:
        path = Path(value).expanduser()
        if not path.is_dir():
            yield value
            continue
        iterator = path.rglob("*") if recursive else path.glob("*")
        for child in sorted(iterator):
            if child.is_file() and child.suffix.lower() in VIDEO_EXTENSIONS:
                yield str(child)


def candidate_label(candidate: ParsedCandidate) -> str:
    pieces = [candidate.kind.upper(), repr(candidate.title)]
    if candidate.year:
        pieces.append(str(candidate.year))
    if candidate.season is not None and candidate.episode is not None:
        pieces.append(f"S{candidate.season:02d}E{candidate.episode:02d}")
    if candidate.tmdb_id:
        pieces.append(f"TMDB={candidate.tmdb_id}")
    if candidate.imdb_id:
        pieces.append(f"IMDb={candidate.imdb_id}")
    pieces.append(f"source={candidate.source}")
    return " | ".join(pieces)


def print_human(result: MatchResult, parse_only: bool = False) -> None:
    print(f"\nInput: {result.input_path}")
    print("Parsed candidates:")
    for candidate in result.parsed:
        print(f"  - {candidate_label(candidate)}")
    if parse_only:
        return
    if result.selected:
        selected = result.selected
        print("Selected TMDB match:")
        line = f"  {selected['title']} ({selected.get('year') or '?'}) [TMDB {selected['tmdb_id']}] score={selected['score']}"
        print(line)
        if selected.get("episode_details"):
            episode = selected["episode_details"]
            print(f"  S{selected['season']:02d}E{selected['episode']:02d}: {episode.get('name') or '?'}")
        if selected.get("poster_url"):
            print(f"  Poster: {selected['poster_url']}")
        markers = selected.get("markers") or {}
        if markers.get("segments"):
            print("  Markers:")
            for segment in markers["segments"]:
                print(
                    f"    {segment['type']}: {segment.get('start_ms')}..{segment.get('end_ms')} ms "
                    f"({segment['provider']})"
                )
    else:
        print("Selected TMDB match: none")
    if result.alternatives:
        print("Alternatives:")
        for item in result.alternatives:
            print(f"  - {item['title']} ({item.get('year') or '?'}) [TMDB {item['tmdb_id']}] score={item['score']}")
    for error in result.errors:
        print(f"Warning: {error}", file=sys.stderr)


def external_imdb_id(details: dict[str, Any], media_type: str) -> Optional[str]:
    if media_type == "movie":
        value = details.get("imdb_id")
    else:
        external_ids = details.get("external_ids") or {}
        value = external_ids.get("imdb_id") if isinstance(external_ids, dict) else None
    return str(value) if value else None


def print_data_payload(payload: Any) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Parse Infuse-style movie/episode paths and match them with TMDB.",
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Media filename, path, or directory; nonexistent names are accepted",
    )
    parser.add_argument(
        "-f",
        "--filename",
        action="append",
        default=[],
        metavar="NAME",
        help="Parse NAME directly without checking whether it exists; may be repeated",
    )
    parser.add_argument("--type", choices=("auto", "movie", "tv"), default="auto", help="Force media type")
    parser.add_argument(
        "--parser-mode",
        choices=("infuse", "extended"),
        default="infuse",
        help="Infuse 8.5.1 compatibility rules, or broader community rules",
    )
    parser.add_argument(
        "--parser-language",
        default=os.getenv("INFUSE_PARSER_LANGUAGE", "en"),
        help="Infuse localized season/episode words (default: en)",
    )
    parser.add_argument("--language", default="zh-CN", help="TMDB result language (default: zh-CN)")
    parser.add_argument(
        "--thumbnail-language",
        help="Preferred TMDB artwork language (default: same as --language)",
    )
    parser.add_argument("--api-key", default=os.getenv("TMDB_API_KEY", DEFAULT_API_KEY), help="TMDB v3 API key")
    parser.add_argument("--timeout", type=float, default=10.0, help="Network timeout in seconds")
    parser.add_argument("--parse-only", action="store_true", help="Only parse paths; do not call TMDB")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    parser.add_argument("--recursive", action="store_true", help="Recursively scan directory arguments")
    parser.add_argument("--max-candidates", type=int, default=6, help="Maximum title variants queried per input")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--image-config", action="store_true", help="Get TMDB image servers and sizes")
    actions.add_argument("--movie-details", type=int, metavar="TMDB_ID", help="Get complete movie details")
    actions.add_argument("--tv-details", type=int, metavar="TMDB_ID", help="Get complete TV-series details")
    actions.add_argument(
        "--season-details",
        type=int,
        nargs=2,
        metavar=("TMDB_ID", "SEASON"),
        help="Get a TV season and all its episode records",
    )
    actions.add_argument(
        "--episode-details",
        type=int,
        nargs=3,
        metavar=("TMDB_ID", "SEASON", "EPISODE"),
        help="Get complete details for one TV episode",
    )
    parser.add_argument(
        "--download-artwork",
        type=Path,
        metavar="DIRECTORY",
        help="Download poster/backdrop using the details or matched item",
    )
    parser.add_argument(
        "--image-size",
        default="original",
        help="Configured TMDB image size for downloads (default: original)",
    )
    parser.add_argument("--markers", action="store_true", help="Fetch intro/recap/outro/preview timestamps")
    parser.add_argument("--tmdb-id", type=int, help="TMDB ID for a standalone marker lookup")
    parser.add_argument("--imdb-id", help="IMDb series/movie ID for marker fallback")
    parser.add_argument("--season", type=int, help="Season number for a marker lookup")
    parser.add_argument("--episode", type=int, help="Episode number for a marker lookup")
    parser.add_argument("--duration-ms", type=int, help="Exact file duration for release-specific marker matching")
    parser.add_argument(
        "--marker-provider",
        choices=("auto", "theintrodb", "introdb"),
        default="auto",
        help="Marker source; auto uses TheIntroDB then IntroDB.app",
    )
    parser.add_argument(
        "--marker-api-key",
        default=os.getenv("THEINTRODB_API_KEY"),
        help="Optional TheIntroDB bearer token (or THEINTRODB_API_KEY)",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    forced_kind: Optional[Literal["movie", "tv"]] = None if args.type == "auto" else args.type
    client = TMDBClient(
        args.api_key,
        args.language,
        args.timeout,
        thumbnail_language=args.thumbnail_language,
    )
    parser_language = args.parser_language

    # Data actions are intentionally usable without a filename.
    action_payload: Optional[dict[str, Any]] = None
    action_media_type: Optional[Literal["movie", "tv"]] = None
    action_tmdb_id: Optional[int] = None
    action_season: Optional[int] = None
    action_episode: Optional[int] = None
    has_data_action = any(
        (
            args.image_config,
            args.movie_details is not None,
            args.tv_details is not None,
            args.season_details is not None,
            args.episode_details is not None,
        )
    )
    if has_data_action and (args.paths or args.filename):
        print("A details/configuration action cannot be combined with filename inputs.", file=sys.stderr)
        return 2
    if args.image_config and args.download_artwork:
        print("--download-artwork requires movie/TV/season/episode details or a matched filename.", file=sys.stderr)
        return 2
    if args.image_config:
        action_payload = image_configuration_summary(client)
    elif args.movie_details is not None:
        action_tmdb_id = args.movie_details
        action_media_type = "movie"
        action_payload = client.movie_details(action_tmdb_id)
    elif args.tv_details is not None:
        action_tmdb_id = args.tv_details
        action_media_type = "tv"
        action_payload = client.tv_details(action_tmdb_id)
    elif args.season_details is not None:
        action_tmdb_id, action_season = args.season_details
        action_media_type = "tv"
        action_payload = client.season_details(action_tmdb_id, action_season)
    elif args.episode_details is not None:
        action_tmdb_id, action_season, action_episode = args.episode_details
        action_media_type = "tv"
        action_payload = client.episode_full_details(action_tmdb_id, action_season, action_episode)

    if action_payload is not None:
        if args.download_artwork and not args.image_config:
            action_payload["_artwork"] = artwork_payload(
                client,
                action_payload,
                output_dir=args.download_artwork,
                size=args.image_size,
                name_prefix=(
                    f"tmdb_{action_tmdb_id}_s{action_season:02d}e{action_episode:02d}"
                    if action_episode is not None
                    else f"tmdb_{action_tmdb_id}_s{action_season:02d}"
                    if action_season is not None else f"tmdb_{action_tmdb_id}"
                ),
            )
        if args.markers:
            if args.image_config:
                print("--markers cannot be combined with --image-config", file=sys.stderr)
                return 2
            marker_season = args.season if args.season is not None else action_season
            marker_episode = args.episode
            details_for_ids = action_payload
            if action_season is not None:
                details_for_ids = client.tv_details(int(action_tmdb_id))
            imdb_id = args.imdb_id or external_imdb_id(details_for_ids, str(action_media_type))
            action_payload["_markers"] = fetch_markers(
                tmdb_id=action_tmdb_id,
                imdb_id=imdb_id,
                media_type=action_media_type or "movie",
                season=marker_season,
                episode=marker_episode if marker_episode is not None else action_episode,
                duration_ms=args.duration_ms,
                timeout=args.timeout,
                provider=args.marker_provider,
                api_key=args.marker_api_key,
            )
        print_data_payload(action_payload)
        return 0

    # --filename values deliberately bypass all filesystem probing. Positional
    # values retain directory-scanning support and also accept nonexistent paths.
    inputs = list(args.filename) + list(discover_inputs(args.paths, args.recursive))
    if not inputs:
        if not args.markers:
            print("Provide a filename/path, a data action, or --markers with an ID.", file=sys.stderr)
            return 2
        if not args.tmdb_id and not args.imdb_id:
            print("A standalone marker lookup requires --tmdb-id or --imdb-id.", file=sys.stderr)
            return 2
        standalone_type: Literal["movie", "tv"]
        if forced_kind is not None:
            standalone_type = forced_kind
        else:
            standalone_type = "tv" if args.season is not None or args.episode is not None else "movie"
        imdb_id = args.imdb_id
        if (
            standalone_type == "tv"
            and not imdb_id
            and args.tmdb_id
            and args.marker_provider in ("auto", "introdb")
        ):
            try:
                imdb_id = external_imdb_id(client.tv_details(args.tmdb_id), "tv")
            except TMDBError:
                # The primary provider can still use TMDB ID; preserve that path.
                pass
        payload = fetch_markers(
            tmdb_id=args.tmdb_id,
            imdb_id=imdb_id,
            media_type=standalone_type,
            season=args.season,
            episode=args.episode,
            duration_ms=args.duration_ms,
            timeout=args.timeout,
            provider=args.marker_provider,
            api_key=args.marker_api_key,
        )
        print_data_payload(payload)
        return 0 if payload["segments"] else 1

    if args.parse_only and args.markers:
        print("--parse-only cannot fetch --markers; remove one of the options.", file=sys.stderr)
        return 2

    results: list[MatchResult] = []
    for raw_path in inputs:
        if args.parse_only:
            result = MatchResult(
                raw_path,
                parse_media_path(raw_path, forced_kind, args.parser_mode, parser_language),
                None,
                [],
                [],
            )
        else:
            result = match_path(
                raw_path,
                client,
                forced_kind,
                args.parser_mode,
                parser_language,
                max(1, args.max_candidates),
            )
            if result.selected and (args.download_artwork or args.markers):
                selected = result.selected
                selected_type = str(selected["media_type"])
                selected_id = int(selected["tmdb_id"])
                details = (
                    client.tv_details(selected_id)
                    if selected_type == "tv" else client.movie_details(selected_id)
                )
                if args.download_artwork:
                    selected["artwork"] = artwork_payload(
                        client,
                        details,
                        output_dir=args.download_artwork,
                        size=args.image_size,
                        name_prefix=f"tmdb_{selected_id}",
                    )
                if args.markers:
                    selected["markers"] = fetch_markers(
                        tmdb_id=selected_id,
                        imdb_id=args.imdb_id or external_imdb_id(details, selected_type),
                        media_type="tv" if selected_type == "tv" else "movie",
                        season=args.season if args.season is not None else selected.get("season"),
                        episode=args.episode if args.episode is not None else selected.get("episode"),
                        duration_ms=args.duration_ms,
                        timeout=args.timeout,
                        provider=args.marker_provider,
                        api_key=args.marker_api_key,
                    )
        results.append(result)

    if args.json:
        payload: Any = [item.to_jsonable() for item in results]
        if len(payload) == 1:
            payload = payload[0]
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        for result in results:
            print_human(result, args.parse_only)

    if not args.parse_only and any(item.selected is None for item in results):
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (TMDBError, MarkerError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1) from None
