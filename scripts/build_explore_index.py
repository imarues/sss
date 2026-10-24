#!/usr/bin/env python3
"""Incrementally match IPA-AR apps against real App Store genre IDs.

Usage (public imarues/sss repository only):
  python3 scripts/build_explore_index.py --max-queries 220 --delay 1.5
  python3 scripts/build_explore_index.py --self-test

No fuzzy / guessed titles are accepted. A match must have the original exact
bundle ID or a declared numeric App Store track ID. Descriptions such as
"لعبة مدفوعة في المتجر الرسمي" only PRIORITIZE lookup; paid status still
requires a real Apple price > 0 in the country checked.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_URL = "https://ikiraplus.pages.dev/IPA-AR.json"
INDEX_FILE = ROOT / "explore-index.json"
SNAPSHOT_FILE = ROOT / "data" / "IPA-AR.json"
COUNTRY = "us"
SCHEMA = 1
POSITIVE_TTL_HOURS = 168
NEGATIVE_TTL_HOURS = 48
CATEGORIES = [
    {"id": "paid-games", "nameAr": "ألعاب مدفوعة", "nameEn": "Paid Games", "symbol": "creditcard.fill",
     "appleGenreIds": ["6014"], "type": "paid-game", "glow": "#547DF5"},
    {"id": "paid-apps", "nameAr": "تطبيقات مدفوعة", "nameEn": "Paid Apps", "symbol": "creditcard",
     "appleGenreIds": [], "type": "paid-app", "glow": "#748DF5"},
    {"id": "entertainment", "nameAr": "ترفيه", "nameEn": "Entertainment", "symbol": "play.rectangle.fill",
     "appleGenreIds": ["6016"], "type": "genre", "glow": "#E6A477"},
    {"id": "social", "nameAr": "تواصل اجتماعي", "nameEn": "Social Networking", "symbol": "bubble.left.and.bubble.right.fill",
     "appleGenreIds": ["6005"], "type": "genre", "glow": "#5BB7F4"},
    {"id": "action", "nameAr": "أكشن", "nameEn": "Action", "symbol": "bolt.fill",
     "appleGenreIds": ["7001"], "type": "genre", "glow": "#F17D6D"},
    {"id": "sports", "nameAr": "ألعاب رياضية", "nameEn": "Sports Games", "symbol": "trophy.fill",
     "appleGenreIds": ["7016"], "type": "genre", "glow": "#43D1A1"},
    {"id": "racing", "nameAr": "سباقات", "nameEn": "Racing", "symbol": "flag.checkered",
     "appleGenreIds": ["7013"], "type": "genre", "glow": "#F3B35A"},
    {"id": "puzzle", "nameAr": "ألغاز", "nameEn": "Puzzle", "symbol": "puzzlepiece.fill",
     "appleGenreIds": ["7012"], "type": "genre", "glow": "#B083F6"},
    {"id": "simulation", "nameAr": "ألعاب المحاكاة", "nameEn": "Simulation Games", "symbol": "gamecontroller.fill",
     "appleGenreIds": ["7015"], "type": "genre", "glow": "#C179E8"},
    {"id": "photo-video", "nameAr": "صور وفيديو", "nameEn": "Photo & Video", "symbol": "camera.fill",
     "appleGenreIds": ["6008", "6027"], "type": "genre", "glow": "#F278B4"},
    {"id": "productivity", "nameAr": "إنتاجية", "nameEn": "Productivity", "symbol": "checkmark.square.fill",
     "appleGenreIds": ["6007"], "type": "genre", "glow": "#56C7B0"},
    {"id": "utilities", "nameAr": "أدوات", "nameEn": "Utilities", "symbol": "wrench.and.screwdriver.fill",
     "appleGenreIds": ["6002"], "type": "genre", "glow": "#9AABD5"},
    {"id": "adventure", "nameAr": "مغامرات", "nameEn": "Adventure", "symbol": "map.fill",
     "appleGenreIds": ["7002"], "type": "genre", "glow": "#E0A35C"},
    {"id": "strategy", "nameAr": "استراتيجية", "nameEn": "Strategy", "symbol": "chess.rook.fill",
     "appleGenreIds": ["7017"], "type": "genre", "glow": "#B9A2E6"},
    {"id": "education", "nameAr": "تعليم", "nameEn": "Education", "symbol": "book.fill",
     "appleGenreIds": ["6017"], "type": "genre", "glow": "#6FBFDF"},
    {"id": "music", "nameAr": "موسيقى وصوتيات", "nameEn": "Music", "symbol": "music.note",
     "appleGenreIds": ["6011"], "type": "genre", "glow": "#D47DD7"},
]
HEADERS = {"User-Agent": "TurathExploreIndexer/1.0", "Accept": "application/json"}
HINT = re.compile(r"(?:لعبة\s*مدفوعة|مدفوع[ة]?\s*في\s*المتجر|paid\s+game|paid\s+(?:on\s+)?app\s*store)", re.I)
SOCIAL_HINT = re.compile(r"(?:تواصل|اجتماعي|اجتماعية|social|network|chat|telegram|instagram|whatsapp|snapchat|tiktok|facebook|messenger|discord|threads|twitter|reddit|wechat|signal|viber|line\b)", re.I)
ID_KEYS = ("appStoreId", "appstoreId", "itunesId", "trackId")
BUNDLE_KEYS = ("originalBundleIdentifier", "originalBundleId", "bundleIdentifier", "bundleId")


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def stamp(t=None):
    return (t or utc_now()).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_stamp(v):
    try:
        return dt.datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return dt.datetime.fromtimestamp(0, dt.timezone.utc)


def get_json(url, retries=3):
    error = None
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(request, timeout=45) as response:
                if response.status != 200:
                    raise RuntimeError(f"HTTP {response.status} from {url.split('?')[0]}")
                data = response.read(90_000_001)
                if len(data) > 90_000_000:
                    raise RuntimeError("JSON source exceeds 90 MB")
                return json.loads(data.decode("utf-8-sig"))
        except (OSError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
            error = exc
            if attempt + 1 < retries:
                time.sleep(min(2 + 2 * attempt, 8))
    raise RuntimeError(f"Fetch failed: {url.split('?')[0]}: {error}")


def nonempty_string(value):
    return value if isinstance(value, str) and value.strip() else None


def version_for(entry):
    direct = nonempty_string(entry.get("version"))
    if direct:
        return direct
    versions = entry.get("versions") or []
    if isinstance(versions, list) and versions:
        first = next((v for v in versions if isinstance(v, dict)), None)
        if first:
            return nonempty_string(first.get("version")) or ""
    return ""


def app_id(entry):
    # Mirrors KiraSearchEntry.storeApp stableID in the Swift application.
    for name in ("id", "bundleIdentifier", "bundleId"):
        value = entry.get(name)
        if isinstance(value, str):
            return value
    return f"search-{entry.get('name', 'App')}-{version_for(entry)}"


def original_bundle(entry):
    for field in BUNDLE_KEYS:
        raw = nonempty_string(entry.get(field))
        if raw:
            return raw.strip()
    return None


def store_track_id(entry):
    for name in ID_KEYS:
        raw = entry.get(name)
        if isinstance(raw, int) and not isinstance(raw, bool) and raw > 0:
            return str(raw)
        if isinstance(raw, str) and raw.isdecimal() and int(raw) > 0:
            return raw
    return None


def eligible(entry):
    if not isinstance(entry, dict):
        return False
    name = entry.get("name")
    if not isinstance(name, str) or not name.strip():
        return False
    if (nonempty_string(entry.get("fileType")) or "").lower() in ("dylib", "deb", "zip"):
        return False
    return original_bundle(entry) is not None or store_track_id(entry) is not None


def paid_hint(entry):
    return bool(HINT.search(str(entry.get("localizedDescription") or "")))


def social_hint(entry):
    # Lookup priority only: the app is NEVER categorized as social without
    # Apple's confirmed genre 6005.
    clues = " ".join(str(entry.get(key) or "") for key in ("category", "name"))
    return bool(SOCIAL_HINT.search(clues))


def lookup(entry):
    """Only authoritative ID / exact original bundle matches are accepted."""
    bundle = original_bundle(entry)
    track = store_track_id(entry)
    for country in ("us", "iq"):
        if track:
            query = {"id": track, "country": country, "entity": "software"}
        elif bundle:
            query = {"bundleId": bundle, "country": country, "entity": "software"}
        else:
            return None
        url = "https://itunes.apple.com/lookup?" + urllib.parse.urlencode(query)
        reply = get_json(url, retries=2)
        results = reply.get("results") or []
        for apple in results:
            if apple.get("wrapperType") != "software" and apple.get("kind") != "software":
                continue
            returned_bundle = apple.get("bundleId")
            returned_id = str(apple.get("trackId", ""))
            if track and returned_id != track:
                continue
            if not track and (not returned_bundle or returned_bundle.casefold() != bundle.casefold()):
                continue
            genres = {str(v) for v in apple.get("genreIds", [])}
            primary = apple.get("primaryGenreId")
            if primary is not None:
                genres.add(str(primary))
            if not genres:
                continue
            raw_price = apple.get("price")
            try:
                price = float(raw_price) if raw_price is not None else None
            except (ValueError, TypeError):
                price = None
            return {
                "bundleId": returned_bundle,
                "appleId": apple.get("trackId"),
                "genreIds": sorted(genres),
                "primaryGenreId": str(primary) if primary is not None else None,
                "price": price,
                "country": country,
                "matchType": "apple-id" if track else "exact-bundle",
            }
    return None


def memberships(match):
    """Exactly one category per Apple-verified app, or none."""
    if not isinstance(match, dict) or not match.get("genreIds"):
        return []
    genres = set(map(str, match["genreIds"]))
    if "7006" in genres:
        return []
    primary = str(match.get("primaryGenreId") or "")
    is_game = "6014" in genres or any(x.startswith("70") for x in genres)
    price = match.get("price")
    paid = isinstance(price, (int, float)) and not isinstance(price, bool) and price > 0
    if paid:
        return ["paid-games" if is_game else "paid-apps"]
    # Historical cached matches may lack primaryGenreId. Never let a broad
    # Entertainment secondary genre swallow a game with a real game subgenre.
    if is_game:
        game_categories = ("action", "sports", "racing", "puzzle", "simulation", "adventure", "strategy")
        for genre in ([primary] if primary else []) + sorted(genres):
            for cat in CATEGORIES:
                if cat["id"] in game_categories and genre in cat["appleGenreIds"]:
                    return [cat["id"]]
        return []  # Do not mislabel generic games as Entertainment.
    # Prefer primary category, then a deterministic secondary fallback.
    for genre in ([primary] if primary else []) + sorted(genres):
        for cat in CATEGORIES:
            if cat["type"] == "genre" and genre in cat["appleGenreIds"]:
                return [cat["id"]]
    return []

def normalize_entries(root):
    rows = root.get("apps")
    if not isinstance(rows, list):
        raise ValueError("IPA-AR JSON has no apps array")
    seen = set()
    result = []
    for entry in rows:
        if not isinstance(entry, dict):
            continue
        key = app_id(entry)
        if not key or key in seen:
            continue
        seen.add(key)
        if eligible(entry):
            result.append((key, entry))
    return result, len(seen)


def build(source, old, budget, lookup_fn=lookup, now=None, min_delay=1.5):
    now = now or utc_now()
    selected, source_count = normalize_entries(source)
    previous = old.get("matches") or {}
    all_keys = {key for key, _ in selected}
    matches = {k: v for k, v in previous.items()
               if k in all_keys and isinstance(v, dict)}

    outstanding = []
    for key, entry in selected:
        cached = matches.get(key)
        bundle = original_bundle(entry)
        track = store_track_id(entry)
        if cached and cached.get("sourceBundle") != bundle:
            matches.pop(key, None)
            cached = None
        if cached and cached.get("sourceTrackId") != track:
            matches.pop(key, None)
            cached = None
        hours = (now - parse_stamp(cached.get("checkedAt"))).total_seconds() / 3600 if cached else 1e9
        ttl = POSITIVE_TTL_HOURS if cached and cached.get("status") == "matched" else NEGATIVE_TTL_HOURS
        if cached and hours < ttl:
            continue
        outstanding.append((key, entry, cached is None, paid_hint(entry), social_hint(entry), hours))

    # Complete real Social Networking lookups first, then the paid-description
    # hints; neither hint ever determines a category by itself.
    outstanding.sort(key=lambda x: (not x[4], not x[3], not x[2], -x[5], x[0]))
    requests = 0
    errors = 0
    for key, entry, _, _, _, _ in outstanding[:budget]:
        requests += 1
        try:
            apple = lookup_fn(entry)
            matches[key] = {
                "sourceBundle": original_bundle(entry),
                "sourceTrackId": store_track_id(entry),
                "checkedAt": stamp(now),
                "status": "matched" if apple else "unmatched",
                "apple": apple,
                "hadPaidHint": paid_hint(entry),
            }
        except Exception as exc:
            # Transient upstream errors must not invalidate earlier verified data.
            errors += 1
            print(f"Warning: lookup error for {key[:64]}: {exc}", file=sys.stderr)
        if requests % 50 == 0:
            print(f"PROGRESS {requests}/{min(budget, len(outstanding))} new lookups, {errors} transient failures", flush=True)
        if requests < min(budget, len(outstanding)) and min_delay:
            time.sleep(min_delay)

    if requests and errors == requests:
        raise RuntimeError("Every Apple lookup failed; refusing to publish an empty/stale index")

    category_apps = {cat["id"]: [] for cat in CATEGORIES}
    verified = 0
    for key, _ in selected:
        entry = matches.get(key) or {}
        if entry.get("status") != "matched":
            continue
        verified += 1
        for cat_id in memberships(entry.get("apple")):
            category_apps[cat_id].append(key)

    assert sum(map(len, category_apps.values())) == len(set(key for ids in category_apps.values() for key in ids)), "Duplicate app across categories"
    categories = [
        dict(cat, appIDs=category_apps[cat["id"]], count=len(category_apps[cat["id"]]))
        for cat in CATEGORIES
    ]
    result = {
        "schema": SCHEMA, "source": SOURCE_URL, "country": COUNTRY,
        "generatedAt": stamp(now), "sourceCount": source_count,
        "eligibleCount": len(selected), "checkedCount": len(matches),
        "verifiedCount": verified, "lookupRequests": requests,
        "lookupErrors": errors, "categories": categories,
        "matches": matches,
    }
    return result


def self_test():
    sample = {"apps": [
        {"id": "a", "name": "Action 1", "bundleIdentifier": "com.example.a",
         "localizedDescription": "لعبة مدفوعة في المتجر الرسمي"},
        {"id": "b", "name": "Tool", "bundleIdentifier": "com.example.b"},
        {"id": "ignored", "name": "Dylib", "fileType": "dylib",
         "bundleIdentifier": "com.example.x"},
    ]}
    def stub(app):
        if app["id"] == "a":
            return {"genreIds": ["6014", "7001"], "price": 5.0, "country": "us"}
        return {"genreIds": ["6002"], "price": 0.0, "country": "us"}
    value = build(sample, {}, 5, stub, min_delay=0)
    categories = {c["id"]: c for c in value["categories"]}
    assert categories["paid-games"]["appIDs"] == ["a"]
    assert categories["action"]["appIDs"] == []
    assert categories["utilities"]["appIDs"] == ["b"]
    assert categories["sports"]["appIDs"] == []
    assert categories["paid-apps"]["appIDs"] == []
    assert memberships({"genreIds": ["6005", "6007"], "primaryGenreId": "6005", "price": 0}) == ["social"]
    assert memberships({"genreIds": ["6005", "6007"], "primaryGenreId": "6007", "price": 0}) == ["productivity"]
    assert memberships({"genreIds": ["6007"], "primaryGenreId": "6007", "price": 2}) == ["paid-apps"]
    assert memberships({"genreIds": ["6014", "7001"], "primaryGenreId": "7001", "price": 0}) == ["action"]
    assert memberships({"genreIds": ["6014", "6016", "7001"], "price": 0}) == ["action"]
    assert memberships({"genreIds": ["6014", "6016"], "price": 0}) == []
    assert memberships({"genreIds": ["6016"], "price": 0}) == ["entertainment"]
    assert memberships({"genreIds": ["6027"], "price": 0}) == ["photo-video"]
    assert memberships({"genreIds": ["6014", "7015"], "price": 0}) == ["simulation"]
    assert memberships({"genreIds": ["6014", "7015"], "price": 3}) == ["paid-games"]
    assert value["checkedCount"] == 2
    assert value["sourceCount"] == 3
    cached = build(sample, value, 5, lambda _: 1 / 0, min_delay=0)
    assert cached["lookupRequests"] == 0
    assert all(c["count"] == categories[c["id"]]["count"] for c in cached["categories"])
    # Notes must NOT cause paid classification if official price is zero.
    assert "paid-games" not in memberships({"genreIds": ["6014"], "price": 0.0})
    assert not memberships({"genreIds": ["6014", "7006"], "price": 5.0})
    assert social_hint({"name": "Instagram", "category": "Other"})
    assert not social_hint({"name": "Golf Golf", "category": "Arcade"})
    print("All explore classifier regression tests passed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-queries", type=int, default=220)
    parser.add_argument("--delay", type=float, default=1.5,
                        help="Delay between lookups in seconds; be respectful of Apple API rate limits")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    budget = max(1, min(int(args.max_queries), 1900))
    source = get_json(SOURCE_URL)
    SNAPSHOT_FILE.parent.mkdir(parents=True, exist_ok=True)
    SNAPSHOT_FILE.write_text(json.dumps(source, ensure_ascii=False, separators=(",", ":")) + "\n", "utf-8")
    old = {}
    if INDEX_FILE.exists():
        old = json.loads(INDEX_FILE.read_text("utf-8"))
    result = build(source, old, budget, min_delay=max(0.25, min(args.delay, 10.0)))
    tmp = INDEX_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(result, ensure_ascii=False, separators=(",", ":")) + "\n", "utf-8")
    tmp.replace(INDEX_FILE)
    print(json.dumps({
        "sourceCount": result["sourceCount"],
        "eligibleCount": result["eligibleCount"],
        "checkedCount": result["checkedCount"],
        "verifiedCount": result["verifiedCount"],
        "lookupRequests": result["lookupRequests"],
        "lookupErrors": result["lookupErrors"],
        "categories": {c["id"]: c["count"] for c in result["categories"]},
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
