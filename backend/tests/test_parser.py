"""Behavioral examples for deterministic, conservative Egyptian Arabic parsing."""

from datetime import datetime

import pytest
from pydantic import ValidationError

from models.reminder_schema import ParseReminderRequest
from parser.arabic_normalizer import normalize_arabic
from parser.reminder_parser import parse_reminder

NOW = "2026-10-19T10:00:00+03:00"  # Monday, Cairo DST


def parse(text, *, context=None, now=NOW, timezone="Africa/Cairo"):
    return parse_reminder(
        ParseReminderRequest(
            text=text,
            context=context,
            now=now,
            timezone=timezone,
        )
    )


def test_complete_project_example():
    result = parse("عندي مناقشة مشروع التخرج يوم الخميس الساعة اتنين الظهر، فكرني قبلها بساعتين")
    assert result.title == "مناقشة مشروع التخرج"
    assert result.event_datetime == "2026-10-22T14:00:00+03:00"
    assert result.reminder_datetime == "2026-10-22T12:00:00+03:00"
    assert result.remind_before_minutes == 120
    assert result.missing_fields == []
    assert result.question is None


def test_conversation_does_not_lose_collected_slots():
    first = parse("عندي دكتور بكرة")
    assert first.missing_fields == ["time", "remind_before"]
    assert first.question == "الساعة كام؟"
    second = parse("خمسة العصر", context={"title": first.title, "date": first.date})
    assert second.title == "دكتور"
    assert second.time == "17:00"
    assert second.missing_fields == ["remind_before"]
    third = parse(
        "بساعتين",
        context={
            "title": second.title,
            "date": second.date,
            "time": second.time,
        },
    )
    assert third.event_datetime == "2026-10-20T17:00:00+03:00"
    assert third.reminder_datetime == "2026-10-20T15:00:00+03:00"
    assert not third.missing_fields


@pytest.mark.parametrize(
    ("phrase", "expected"),
    [
        ("بكرة", "2026-10-20"),
        ("بكره", "2026-10-20"),
        ("بعد بكرة", "2026-10-21"),
        ("بعد بكره", "2026-10-21"),
        ("اليوم", "2026-10-19"),
        ("النهارده", "2026-10-19"),
        ("الثلاثاء", "2026-10-20"),
        ("الاربعاء", "2026-10-21"),
        ("الخميس الجاي", "2026-10-22"),
        ("الجمعة", "2026-10-23"),
        ("السبت", "2026-10-24"),
        ("الأحد القادم", "2026-10-25"),
        ("الاثنين", "2026-10-26"),
        ("يوم 25 أكتوبر", "2026-10-25"),
        ("يوم ١ نوفمبر", "2026-11-01"),
        ("22/10/2026", "2026-10-22"),
        ("٢٢/١٠/٢٠٢٦", "2026-10-22"),
        ("2026-10-22", "2026-10-22"),
        ("22/10", "2026-10-22"),
        ("1/1", "2027-01-01"),
    ],
)
def test_dates(phrase, expected):
    result = parse(f"عندي دكتور {phrase} الساعة 17:00 فكرني قبله بساعة")
    assert result.date == expected
    assert result.title == "دكتور"
    assert result.missing_fields == []


@pytest.mark.parametrize(
    ("phrase", "expected"),
    [
        ("الساعة تلاته الضهر", "15:00"),
        ("الساعة خمسة العصر", "17:00"),
        ("الساعة ٥ مساء", "17:00"),
        ("الساعة ۰۵ صباحا", "05:00"),
        ("الساعة تمانية الصبح", "08:00"),
        ("الساعة تسعة بالليل", "21:00"),
        ("الساعة احد عشر صباح", "11:00"),
        ("الساعة اتناشر الظهر", "12:00"),
        ("الساعة 12 صباح", "00:00"),
        ("الساعة 13", "13:00"),
        ("الساعة 23:59", "23:59"),
        ("00:15", "00:15"),
        ("الساعة خمسة ونص العصر", "17:30"),
        ("الساعة خمسة وربع مساء", "17:15"),
        ("الساعة خمسة إلا ربع مساء", "16:45"),
        ("الساعة 12 الا ربع صباح", "23:45"),
        ("الساعة 5:45 pm", "17:45"),
        ("الساعة 5 بعد الظهر", "17:00"),
        ("الساعة خمسة و عشرين دقيقة مساء", "17:20"),
    ],
)
def test_times(phrase, expected):
    result = parse(f"عندي اجتماع بكرة {phrase} فكرني قبله بربع ساعة")
    assert result.time == expected
    assert result.missing_fields == []


@pytest.mark.parametrize(
    "time",
    [
        "الساعة خمسة",
        "الساعة 1",
        "الساعة 12",
        "الساعة 05:00",
        "الساعة ٧ ونص",
        "الساعة 24:00",
        "الساعة 17:60",
        "الساعة 13 مساء",
    ],
)
def test_ambiguous_or_invalid_time_is_never_scheduled(time):
    result = parse(f"عندي دكتور الخميس {time} فكرني قبله بساعتين")
    assert result.time is None
    assert "time" in result.missing_fields
    assert "time" in result.ambiguous_fields
    assert result.event_datetime is None
    assert result.reminder_datetime is None
    assert result.question


@pytest.mark.parametrize(
    ("phrase", "expected"),
    [
        ("بساعتين", 120),
        ("بساعة", 60),
        ("بثلاث ساعات", 180),
        ("بربع ساعة", 15),
        ("بنص ساعة", 30),
        ("بنصف ساعة", 30),
        ("بثلث ساعة", 20),
        ("بخمسة دقايق", 5),
        ("ب١٥ دقيقة", 15),
        ("بساعة ونص", 90),
        ("بساعتين وربع", 135),
        ("بساعة و15 دقيقة", 75),
        ("بعشر دقائق", 10),
        ("بدقيقة", 1),
        ("بدقيقتين", 2),
    ],
)
def test_offsets(phrase, expected):
    result = parse(f"عندي دكتور بكرة الساعة 17:00 فكرني قبله {phrase}")
    assert result.remind_before_minutes == expected
    assert result.missing_fields == []


def test_zero_offset_is_valid_and_not_missing():
    result = parse("عندي دكتور بكرة الساعة 17:00 فكرني في نفس الموعد")
    assert result.remind_before_minutes == 0
    assert result.event_datetime == result.reminder_datetime
    assert result.missing_fields == []


@pytest.mark.parametrize("phrase", ["31/02/2027", "2027-13-01", "31 ابريل 2027"])
def test_invalid_date_does_not_silently_roll_over(phrase):
    result = parse(f"عندي دكتور {phrase} الساعة 17:00 فكرني قبله بساعتين")
    assert result.date is None
    assert "date" in result.ambiguous_fields
    assert result.event_datetime is None


def test_past_event_asks_for_new_date():
    result = parse("عندي دكتور اليوم الساعة خمسة صباح فكرني قبله بساعة")
    assert result.date is None
    assert "date" in result.missing_fields
    assert result.event_datetime is None
    assert "فات" in result.question


def test_past_notification_does_not_change_event():
    result = parse("عندي دكتور اليوم الساعة 11 صباح فكرني قبله بساعتين")
    assert result.event_datetime == "2026-10-19T11:00:00+03:00"
    assert result.reminder_datetime is None
    assert result.remind_before_minutes is None
    assert result.missing_fields == ["remind_before"]
    assert "فات" in result.question


def test_negative_offset_is_rejected_instead_of_becoming_positive():
    result = parse("عندي دكتور بكرة الساعة 17:00 فكرني قبله ب-2 ساعات")
    assert result.remind_before_minutes is None
    assert "remind_before" in result.missing_fields


@pytest.mark.parametrize("phrase", ["بساعة الا ربع", "بساعة وخمس ساعات", "بواحد وعشرين ساعة"])
def test_unsupported_duration_is_not_silently_shortened(phrase):
    result = parse(f"عندي دكتور بكرة الساعة 17:00 فكرني قبله {phrase}")
    assert result.remind_before_minutes is None
    assert result.title == "دكتور"
    assert "remind_before" in result.missing_fields


@pytest.mark.parametrize("phrase", ["17:000", "17:xx", "-17:00", "17.30"])
def test_malformed_time_is_not_silently_shortened(phrase):
    result = parse(f"عندي دكتور بكرة الساعة {phrase} فكرني قبله بساعة")
    assert result.time is None
    assert result.event_datetime is None


def test_existing_slots_can_be_corrected():
    result = parse(
        "بعد بكرة الساعة ستة العصر",
        context={
            "title": "دكتور",
            "date": "2026-10-20",
            "time": "17:00",
            "remind_before_minutes": 120,
        },
    )
    assert result.title == "دكتور"
    assert result.date == "2026-10-21"
    assert result.time == "18:00"
    assert result.reminder_datetime == "2026-10-21T16:00:00+03:00"


@pytest.mark.parametrize("reply", ["أيوه", "مساء", "تمام"])
def test_non_slot_followup_preserves_existing_title(reply):
    result = parse(reply, context={"title": "دكتور", "date": "2026-10-20"})
    assert result.title == "دكتور"
    assert result.time is None
    assert result.reminder_datetime is None
    assert "time" in result.missing_fields


def test_bare_hour_question_requires_complete_hour_in_reply():
    result = parse("عندي دكتور بكرة الساعة خمسة")
    assert result.time is None
    assert "الساعة كاملة" in result.question


def test_title_correction_requires_explicit_title_intent():
    result = parse("العنوان دكتور أسنان", context={"title": "دكتور", "date": "2026-10-20"})
    assert result.title == "دكتور اسنان"


def test_fikrni_title_prefix():
    result = parse("فكرني بالدكتور بكرة الساعة تمانية صباح فكرني قبله بنص ساعة")
    assert result.title == "الدكتور"
    assert result.remind_before_minutes == 30


def test_missing_title_is_requested_instead_of_invented():
    result = parse("بكرة الساعة خمسة العصر قبلها بساعتين")
    assert result.title is None
    assert result.missing_fields == ["title"]
    assert result.question == "اسم الموعد إيه؟"


def test_normalization_retains_numbers_and_meaning():
    assert normalize_arabic("عِنْدي دكتور بكره الساعه ٥ الضهر") == "عندي دكتور بكرة الساعة 5 الظهر"


def test_timezone_includes_offset_and_uses_local_calendar():
    result = parse("عندي دكتور بكرة الساعة 17:00 قبلها بساعة", now="2026-10-19T23:30:00+00:00")
    assert result.date == "2026-10-21"
    assert result.event_datetime.endswith("+03:00")


def test_cairo_winter_offset():
    result = parse("عندي دكتور 01/11/2026 الساعة 17:00 قبلها بساعة")
    assert result.event_datetime == "2026-11-01T17:00:00+02:00"


@pytest.mark.parametrize(
    ("date", "time", "now"),
    [
        ("2027-04-30", "00:30", "2027-04-28T10:00:00+02:00"),
        ("2026-10-29", "23:30", NOW),
    ],
)
def test_dst_nonexistent_or_repeated_clock_time_requires_clarification(date, time, now):
    result = parse(f"عندي دكتور {date} الساعة {time} قبلها بساعة", now=now)
    assert result.time is None
    assert result.event_datetime is None
    assert "time" in result.ambiguous_fields


def test_offsets_are_elapsed_minutes_across_daylight_saving():
    result = parse("عندي دكتور 2026-10-30 الساعة 00:30 قبلها بساعتين")
    event = datetime.fromisoformat(result.event_datetime)
    reminder = datetime.fromisoformat(result.reminder_datetime)
    assert (event - reminder).total_seconds() == 7200


def test_already_elapsed_first_fold_notification_is_rejected_in_second_fold():
    # Cairo repeats 23:00 at the end of DST. 23:30 +03 happened before 23:15 +02.
    result = parse(
        "عندي دكتور 2026-10-30 الساعة 00:30 قبلها بساعتين",
        now="2026-10-29T23:15:00+02:00",
    )
    assert result.event_datetime == "2026-10-30T00:30:00+02:00"
    assert result.reminder_datetime is None
    assert result.missing_fields == ["remind_before"]


@pytest.mark.parametrize(
    "data",
    [
        {"text": " "},
        {"text": "a", "timezone": "Not/AZone"},
        {"text": "a", "now": "2026-10-19T10:00:00"},
        {"text": "a", "context": {"remind_before_minutes": -1}},
        {"text": "a", "context": {"time": "25:00"}},
        {"text": "a", "context": {"date": "2026-02-31"}},
    ],
)
def test_invalid_request_values_are_rejected(data):
    with pytest.raises(ValidationError):
        ParseReminderRequest(**data)
