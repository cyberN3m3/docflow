"""File names people give their files, kept as they wrote them.

Names keep letters from every script (Yoruba tone marks, Igbo dots, Hausa
hooks, Arabic, Chinese...). Only what is unsafe is removed: folders in the
name ("../"), control characters and the characters that break file systems
or HTTP headers. Storage keys never contain the name, so S3 and the disk only
ever see plain ASCII paths.
"""
import re
import unicodedata
from urllib.parse import quote

MAX_NAME_CHARS = 150
_KEEP_PUNCTUATION = set(" ._-()[]&+,'")


def safe_filename(name: str | None) -> str:
    name = unicodedata.normalize("NFC", name or "")
    name = name.replace("\\", "/").rsplit("/", 1)[-1]  # drop any folder part, Windows or POSIX
    cleaned = "".join(
        ch if ch.isalnum() or unicodedata.category(ch).startswith("M") or ch in _KEEP_PUNCTUATION else "_"
        for ch in name
    )
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .") or "file"
    if len(cleaned) > MAX_NAME_CHARS:  # shorten the stem, keep the extension
        stem, dot, ext = cleaned.rpartition(".")
        if dot and 0 < len(ext) <= 10:
            cleaned = stem[: MAX_NAME_CHARS - len(ext) - 1].rstrip(" .") + "." + ext
        else:
            cleaned = cleaned[:MAX_NAME_CHARS]
    return cleaned


def ascii_fallback(name: str, default: str = "document.pdf") -> str:
    """For old clients that ignore filename*: accents dropped, other scripts replaced."""
    def to_ascii(text: str) -> str:
        plain = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
        return re.sub(r"[^A-Za-z0-9._ ()-]", "_", plain)

    stem, dot, ext = name.rpartition(".")
    if not dot:
        stem, ext = name, ""
    stem, ext = to_ascii(stem).strip(" ._-"), to_ascii(ext).strip(" ._-")
    if not re.search(r"[A-Za-z0-9]", stem):
        return default
    return f"{stem}.{ext}" if ext else stem


def content_disposition(name: str) -> str:
    """attachment header that keeps a non-English name (RFC 6266 / RFC 5987)."""
    return f"attachment; filename=\"{ascii_fallback(name)}\"; filename*=UTF-8''{quote(name, safe='')}"
