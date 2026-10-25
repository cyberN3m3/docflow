"""File storage behind one small interface.

Two backends with the same methods, so the rest of the app never knows
which one it is using:

  LocalStorage  files on a local disk (the legacy single server)
  S3Storage     files in an S3 bucket (AWS)

STORAGE_BACKEND picks one. Only S3 can hand out download links
(presigned URLs); LocalStorage returns None and the app streams the file.
"""
from functools import lru_cache
from pathlib import Path

from .config import settings
from .filenames import content_disposition


class LocalStorage:
    def __init__(self, root: str) -> None:
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if not path.is_relative_to(self.root):
            raise ValueError("Invalid storage key")
        return path

    def save(self, key: str, data: bytes) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def read(self, key: str) -> bytes:
        return self._path(key).read_bytes()

    def exists(self, key: str) -> bool:
        return self._path(key).exists()

    def delete(self, key: str) -> None:
        self._path(key).unlink(missing_ok=True)

    def download_url(self, key: str, filename: str) -> str | None:
        return None  # no links from a local disk; the app streams the file


class S3Storage:
    """Stores files in S3. Credentials come from the ECS task role, never from code."""

    def __init__(self, bucket: str, region: str, url_expiry: int = 300) -> None:
        import boto3  # imported here so the legacy stack doesn't need AWS libraries loaded
        from botocore.config import Config

        self.bucket = bucket
        self.url_expiry = url_expiry
        # Signature Version 4: the current signing method. Older SigV2 links
        # are being retired by AWS and don't work with every bucket setting.
        self.client = boto3.client(
            "s3",
            region_name=region,
            config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
        )

    def save(self, key: str, data: bytes) -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data)

    def read(self, key: str) -> bytes:
        return self.client.get_object(Bucket=self.bucket, Key=key)["Body"].read()

    def exists(self, key: str) -> bool:
        from botocore.exceptions import ClientError

        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                return False
            raise

    def delete(self, key: str) -> None:
        self.client.delete_object(Bucket=self.bucket, Key=key)

    def download_url(self, key: str, filename: str) -> str:
        """A short-lived link straight to S3, so large files never pass through the web server."""
        return self.client.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": self.bucket,
                "Key": key,
                "ResponseContentDisposition": content_disposition(filename),
                "ResponseContentType": "application/pdf",
            },
            ExpiresIn=self.url_expiry,
        )


@lru_cache(maxsize=1)
def _storage(backend: str, root: str, bucket: str | None, region: str, expiry: int):
    if backend == "s3":
        return S3Storage(bucket, region, expiry)
    return LocalStorage(root)


def get_storage():
    return _storage(
        settings.storage_backend,
        settings.storage_dir,
        settings.s3_bucket,
        settings.aws_region,
        settings.download_url_expiry,
    )
