"""Thin client for Gotenberg (https://gotenberg.dev), which does the actual conversions."""
import httpx

from .config import settings

CONVERTIBLE_EXTENSIONS = {
    "doc", "docx", "odt", "rtf", "txt",
    "xls", "xlsx", "ods", "csv",
    "ppt", "pptx", "odp",
    "jpg", "jpeg", "png",
}

TIMEOUT = httpx.Timeout(120.0, connect=5.0)


def convert_to_pdf(filename: str, data: bytes) -> bytes:
    """Office document or image -> PDF via LibreOffice."""
    resp = httpx.post(
        f"{settings.gotenberg_url}/forms/libreoffice/convert",
        files={"files": (filename, data)},
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    return resp.content


def merge_pdfs(files: list[tuple[str, bytes]]) -> bytes:
    """Merge PDFs in the given order.

    Gotenberg merges in alphanumeric filename order, so we prefix an index.
    """
    payload = [("files", (f"{i:03d}_{name}", data)) for i, (name, data) in enumerate(files)]
    resp = httpx.post(
        f"{settings.gotenberg_url}/forms/pdfengines/merge",
        files=payload,
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    return resp.content
