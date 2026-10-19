"""Public, typed reminder API contract shared by the mobile conversation flow."""

from datetime import date as Date
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, Field, field_validator


class ReminderContext(BaseModel):
    title: str | None = Field(default=None, max_length=200)
    date: Date | None = None
    time: str | None = Field(default=None, pattern=r"^(?:[01]\d|2[0-3]):[0-5]\d$")
    remind_before_minutes: int | None = Field(default=None, ge=0, le=525600)


class ParseReminderRequest(BaseModel):
    text: str = Field(min_length=1, max_length=4000)
    timezone: str = "Africa/Cairo"
    now: datetime | None = None
    context: ReminderContext | None = None

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Use a valid IANA timezone, for example Africa/Cairo") from exc
        return value

    @field_validator("now")
    @classmethod
    def aware_now(cls, value: datetime | None) -> datetime | None:
        if value is not None and (value.tzinfo is None or value.utcoffset() is None):
            raise ValueError("now must include a UTC offset")
        return value

    @field_validator("text")
    @classmethod
    def nonblank_text(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("text must not be blank")
        return value.strip()


class ParseReminderResponse(BaseModel):
    title: str | None = None
    date: str | None = None
    time: str | None = None
    event_datetime: str | None = None
    reminder_datetime: str | None = None
    remind_before_minutes: int | None = None
    missing_fields: list[str] = Field(default_factory=list)
    ambiguous_fields: list[str] = Field(default_factory=list)
    question: str | None = None
