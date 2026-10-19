"""Conservative Egyptian Arabic slot extraction with explicit conversation context.

Bare 12-hour times never acquire an invented AM/PM value. No request is scheduled
until every slot is known, valid and future, including the notification itself.
"""

import re
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from models.reminder_schema import ParseReminderRequest, ParseReminderResponse
from parser.arabic_normalizer import NUMBER_PATTERN, normalize_arabic, number_value
from parser.date_parser import extract_date

Span = tuple[int, int]
PERIOD = r"(?:بعد\s+الظهر|صباح|مساء|العصر|عصرا|الظهر|ظهرا|المغرب|الفجر|ص|م|am|pm)"
TIME_PATTERN = re.compile(
    rf"(?<!\w)(?:الساعة\s+)?(?P<hour>{NUMBER_PATTERN})"
    rf"(?:(?::(?P<minutes>\d{{1,2}}))|"
    rf"\s*(?P<except>الا)\s+(?P<less>ربع|نصف)|"
    rf"\s*و\s*(?P<fraction>ربع|نصف|ثلث)|"
    rf"\s*و\s*(?P<word_minutes>{NUMBER_PATTERN})\s*(?:دقيقة|دقايق)?)?"
    rf"(?:\s+(?P<period>{PERIOD}))?(?!\w)",
    re.IGNORECASE,
)


def _extract_offset(text: str) -> tuple[int | None, Span | None, bool]:
    zero = re.search(r"(?:في\s+نفس\s+(?:الوقت|المعاد|الموعد)|وقتها|في\s+المعاد)", text)
    if zero:
        return 0, zero.span(), False
    # Require a before marker for full sentences. A short reply may be only a duration.
    marker = re.search(r"(?:فكرني|ذكرني)?\s*(?:قبلها|قبله|قبل\s+الموعد|قبل\s+الحدث|قبل)\s*", text)
    fragment = text[marker.end() :] if marker else text
    fragment = re.sub(r"^(?:فكرني|ذكرني)\s*", "", fragment).strip()
    if re.match(r"ب?\s*-", fragment):
        return None, (marker.start() if marker else 0, len(text)), True
    if not marker and len(fragment.split()) > 7:
        return None, None, False
    duration = re.compile(
        rf"(?<!\w)ب?\s*(?:"
        rf"(?P<fraction>ربع|نصف|ثلث)\s+ساعة|"
        rf"(?P<hours>{NUMBER_PATTERN})\s*(?:ساعات|ساعة)|"
        rf"(?P<dual>ساعتين|ساعتان)|(?P<one>ساعة)|"
        rf"(?P<minutes>{NUMBER_PATTERN})\s*(?:دقيقة|دقائق|دقايق)|"
        rf"(?P<dual_minutes>دقيقتين)|(?P<one_minute>دقيقة)"
        rf")(?:\s*و\s*(?P<extra_fraction>ربع|نصف|ثلث))?(?!\w)"
    ).match(fragment)
    if not duration:
        return None, (marker.start(), len(text)) if marker else None, bool(marker)
    if not marker and duration.group().strip() != fragment:
        return None, None, False
    groups = duration.groupdict()
    value = 0
    if groups["fraction"]:
        value = {"ربع": 15, "نصف": 30, "ثلث": 20}[groups["fraction"]]
    elif groups["hours"]:
        value = (number_value(groups["hours"]) or 0) * 60
    elif groups["minutes"]:
        value = number_value(groups["minutes"]) or 0
    elif groups["dual"]:
        value = 120
    elif groups["one"]:
        value = 60
    elif groups["dual_minutes"]:
        value = 2
    else:
        value = 1
    if groups["extra_fraction"]:
        value += {"ربع": 15, "نصف": 30, "ثلث": 20}[groups["extra_fraction"]]
    start = marker.start() if marker else duration.start()
    end = marker.end() + duration.end() if marker else duration.end()
    # Mixed units such as ساعة و 15 دقيقة are additive.
    remainder = fragment[duration.end() :]
    extra = re.match(rf"\s*و\s*({NUMBER_PATTERN})\s*(?:دقيقة|دقائق|دقايق)(?!\w)", remainder)
    if extra:
        value += number_value(extra.group(1)) or 0
        end += extra.end()
    tail = remainder[extra.end() :] if extra else remainder
    if tail.strip(" .") and not re.fullmatch(r"\s*(?:لو سمحت|من فضلك)\s*", tail):
        return None, (start, len(text)), True
    if value > 525600:
        return None, (start, end), True
    return value, (start, end), False


def _without(text: str, spans: list[Span]) -> str:
    chars = list(text)
    for start, end in spans:
        chars[start:end] = [" "] * (end - start)
    return "".join(chars)


def _extract_time(text: str, standalone: bool) -> tuple[str | None, Span | None, bool]:
    for match in TIME_PATTERN.finditer(text):
        marked = match.group().startswith("الساعة")
        explicit = marked or match.group("period") or match.group("minutes") is not None
        if not explicit and not (standalone and match.group().strip() == text.strip()):
            continue
        # A partial match must not turn malformed 17:000 into a valid 17:00.
        if (match.start() and text[match.start() - 1] == "-") or (
            match.end() < len(text) and text[match.end()] in ":."
        ):
            return None, (match.start(), len(text)), True
        hour = number_value(match.group("hour"))
        assert hour is not None
        minute = int(match.group("minutes") or 0)
        if match.group("fraction"):
            minute = {"ربع": 15, "نصف": 30, "ثلث": 20}[match.group("fraction")]
        if match.group("less"):
            hour -= 1
            minute = 60 - {"ربع": 15, "نصف": 30}[match.group("less")]
        if match.group("word_minutes"):
            minute = number_value(match.group("word_minutes")) or 0
        period = (match.group("period") or "").lower()
        raw_hour = number_value(match.group("hour")) or 0
        if minute > 59 or hour < 0 or raw_hour > 23:
            return None, match.span(), True
        if period:
            if not 1 <= raw_hour <= 12:
                return None, match.span(), True
            # Apply the period to the stated hour before subtracting "إلا ربع".
            pm = period in {
                "مساء",
                "العصر",
                "عصرا",
                "الظهر",
                "ظهرا",
                "المغرب",
                "م",
                "pm",
                "بعد الظهر",
            }
            hour = raw_hour % 12 + (12 if pm else 0)
            if match.group("less"):
                hour = (hour - 1) % 24
        elif 1 <= raw_hour <= 12:
            return None, match.span(), True
        return f"{hour:02d}:{minute:02d}", match.span(), False
    return None, None, False


def _extract_title(text: str, spans: list[Span], has_context: bool) -> str | None:
    remainder = _without(text, spans)
    remainder = re.sub(r"^\s*(?:فكرني|ذكرني)\s+ب(?:ـ)?", "", remainder)
    remainder = re.sub(r"(?:فكرني|ذكرني)(?:\s+(?:قبلها|قبله|قبل))?.*$", "", remainder)
    remainder = re.sub(r"^\s*(?:عندي\s+ميعاد|عندي|عندنا|تذكير\s+ب)\s*", "", remainder)
    remainder = re.sub(r"\b(?:يوم|الساعة|الساعه|في|الميعاد|الموعد)\b", " ", remainder)
    remainder = re.sub(r"\s+", " ", remainder).strip(" .،-")
    if not remainder or len(remainder) > 200:
        return None
    # Slot replies must not replace an already collected title.
    if has_context and not re.match(r"^(?:عندي|العنوان|اسم\s+الموعد)", text):
        return None
    return re.sub(r"^(?:العنوان|اسم\s+الموعد)\s*", "", remainder) or None


def parse_reminder(request: ParseReminderRequest) -> ParseReminderResponse:
    zone = ZoneInfo(request.timezone)
    now = (request.now or datetime.now(timezone.utc)).astimezone(zone)
    context = request.context
    result = ParseReminderResponse(
        title=context.title if context else None,
        date=context.date.isoformat() if context and context.date else None,
        time=context.time if context else None,
        remind_before_minutes=context.remind_before_minutes if context else None,
    )
    text = normalize_arabic(request.text)
    spans: list[Span] = []
    offset, offset_span, invalid_offset = _extract_offset(text)
    if offset_span:
        spans.append(offset_span)
        result.remind_before_minutes = offset
    date_value, date_span, invalid_date = extract_date(_without(text, spans), now)
    if date_span:
        spans.append(date_span)
        result.date = date_value.isoformat() if date_value else None
    time_text = _without(text, spans)
    time_value, time_span, unclear_time = _extract_time(time_text, standalone=True)
    if time_span:
        spans.append(time_span)
        result.time = time_value
    title = _extract_title(text, spans, context is not None and bool(context.title))
    if title:
        result.title = title
    if invalid_date:
        result.ambiguous_fields.append("date")
    if unclear_time:
        result.ambiguous_fields.append("time")
    if invalid_offset:
        result.ambiguous_fields.append("remind_before")
    special_question = None
    if result.date and result.time:
        naive = datetime.fromisoformat(f"{result.date}T{result.time}:00")
        event = naive.replace(tzinfo=zone)
        roundtrip = event.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None)
        if roundtrip != naive or event.utcoffset() != event.replace(fold=1).utcoffset():
            result.time = None
            result.ambiguous_fields.append("time")
            special_question = "الساعة دي فيها تغيير للتوقيت الصيفي. اختار وقت تاني واضح."
        elif event.astimezone(timezone.utc) <= now.astimezone(timezone.utc):
            result.date = None
            result.ambiguous_fields.append("date")
            special_question = "الموعد ده فات. تحب تختار تاريخ تاني في المستقبل؟"
        else:
            result.event_datetime = event.isoformat()
            if result.remind_before_minutes is not None:
                # Arithmetic on UTC is deliberate: duration means elapsed minutes across DST.
                reminder = (
                    event.astimezone(timezone.utc) - timedelta(minutes=result.remind_before_minutes)
                ).astimezone(zone)
                if reminder.astimezone(timezone.utc) <= now.astimezone(timezone.utc):
                    result.remind_before_minutes = None
                    special_question = "وقت التذكير فات. تحب أفكرك قبل الموعد بقد إيه؟"
                else:
                    result.reminder_datetime = reminder.isoformat()
    result.missing_fields = [
        field
        for field, value in (
            ("title", result.title),
            ("date", result.date),
            ("time", result.time),
            ("remind_before", result.remind_before_minutes),
        )
        if value is None
    ]
    result.ambiguous_fields = list(dict.fromkeys(result.ambiguous_fields))
    if special_question:
        result.question = special_question
    elif "time" in result.ambiguous_fields:
        result.question = "قول الساعة كاملة مع صباح او مساء، زي خمسة العصر."
    elif "date" in result.ambiguous_fields:
        result.question = "التاريخ مش صحيح. تحب الموعد يوم إيه؟"
    elif result.missing_fields:
        result.question = {
            "title": "اسم الموعد إيه؟",
            "date": "الموعد يوم إيه؟",
            "time": "الساعة كام؟",
            "remind_before": "تحب أفكرك قبله بقد إيه؟",
        }[result.missing_fields[0]]
    return result
