"""
PII scrubber for log safety. Not a security boundary — never trust a regex with
your compliance posture. For real PHI/PII enforcement, use Cloud DLP API as a
pre-processing step. This module is sufficient for log redaction.
"""
import re

_PATTERNS = [
    # Email
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), "[EMAIL]"),
    # E.164-ish phone numbers
    (re.compile(r"\b\+?\d{1,3}[-.\s]?\(?\d{1,4}\)?[-.\s]?\d{3,4}[-.\s]?\d{4}\b"), "[PHONE]"),
    # SSN
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[SSN]"),
    # Credit-card-ish (13-19 digits, Luhn not validated here)
    (re.compile(r"\b(?:\d[ -]?){13,19}\b"), "[CARD]"),
    # IPv4
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "[IP]"),
    # AWS-style access keys
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[AWS_KEY]"),
    # Generic bearer tokens
    (re.compile(r"\bBearer\s+[A-Za-z0-9._\-]+", re.I), "Bearer [TOKEN]"),
]

def scrub(text: str) -> str:
    for pat, repl in _PATTERNS:
        text = pat.sub(repl, text)
    return text
