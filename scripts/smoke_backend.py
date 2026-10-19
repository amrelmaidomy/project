#!/usr/bin/env python3
"""Exercise the running API without loading a speech model or changing local data."""
from datetime import datetime, timedelta
import json
import os
from urllib.request import Request, urlopen

base_url = os.environ.get("API_BASE_URL", "http://127.0.0.1:8000").rstrip("/")


def request(path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = Request(base_url + path, data=body, headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=20) as response:
        return json.load(response)


health = request("/health")
assert health["status"] == "ok", health
parsed = request("/parse-reminder", {
    "text": "عندي اختبار بكرة الساعة 17:00 فكرني قبله بساعتين",
    "timezone": "Africa/Cairo",
})
assert not parsed["missing_fields"] and not parsed["ambiguous_fields"], parsed
assert parsed["title"] == "اختبار", parsed
assert parsed["remind_before_minutes"] == 120, parsed
event = datetime.fromisoformat(parsed["event_datetime"])
reminder = datetime.fromisoformat(parsed["reminder_datetime"])
assert event - reminder == timedelta(hours=2), parsed
print("API health and Arabic reminder parsing passed; speech model state:", health["speech"]["state"])
