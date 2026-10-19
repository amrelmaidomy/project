"""Date extraction is explicit: only date-shaped expressions enter dateparser."""

import re
from datetime import date, datetime, timedelta

import dateparser

WEEKDAYS = {
    "الاثنين": 0,
    "الثلاثاء": 1,
    "الاربعاء": 2,
    "الخميس": 3,
    "الجمعة": 4,
    "السبت": 5,
    "الاحد": 6,
}
MONTHS = "يناير|فبراير|مارس|ابريل|مايو|يونيو|يوليو|اغسطس|سبتمبر|اكتوبر|نوفمبر|ديسمبر"


def extract_date(text: str, now: datetime) -> tuple[date | None, tuple[int, int] | None, bool]:
    """Return date, expression span, invalid flag (do not replace invalid dates)."""
    relative = re.search(
        r"(?<!\w)(بعد\s+(?:بكرة|غدا)|بكرة|غدا|النهاردة|النهارده|اليوم)(?!\w)", text
    )
    if relative:
        phrase = relative.group()
        days = 2 if phrase.startswith("بعد") else (1 if phrase in {"بكرة", "غدا"} else 0)
        return now.date() + timedelta(days=days), relative.span(), False
    weekday = re.search(
        r"(?<!\w)(?:يوم\s+)?(" + "|".join(WEEKDAYS) + r")(?:\s+(?:الجاي|القادم|المقبل))?(?!\w)",
        text,
    )
    if weekday:
        days = (WEEKDAYS[weekday.group(1)] - now.weekday()) % 7 or 7
        return now.date() + timedelta(days=days), weekday.span(), False
    iso = re.search(r"(?<!\d)(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)", text)
    numeric = re.search(r"(?<![\d/])(\d{1,2})[/\-](\d{1,2})(?:[/\-](\d{4}))?(?![\d/])", text)
    if iso or numeric:
        match = iso or numeric
        assert match is not None
        try:
            if iso:
                result = date(*map(int, iso.groups()))
            else:
                assert numeric is not None
                day, month, year = numeric.groups()
                result = date(int(year) if year else now.year, int(month), int(day))
                if not year and result < now.date():
                    result = result.replace(year=now.year + 1)
            return result, match.span(), False
        except ValueError:
            return None, match.span(), True
    named = re.search(r"(?<!\w)(?:يوم\s+)?\d{1,2}\s+(?:" + MONTHS + r")(?:\s+\d{4})?(?!\w)", text)
    if named:
        parsed = dateparser.parse(
            re.sub(r"^يوم\s+", "", named.group()),
            languages=["ar"],
            settings={
                "RELATIVE_BASE": now.replace(tzinfo=None),
                "PREFER_DATES_FROM": "future",
                "DATE_ORDER": "DMY",
                "REQUIRE_PARTS": ["day", "month"],
            },
        )
        return parsed.date() if parsed else None, named.span(), parsed is None
    return None, None, False
