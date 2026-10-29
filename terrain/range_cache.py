"""Bounded, conditional HTTP range reads with a persistent LRU block cache."""

import hashlib
import http.client
import io
import os
import ssl
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit

import certifi


class TerrainError(Exception):
    """A source or resource limit prevented a complete terrain calculation."""


class Budget:
    """Account for downloaded bytes, HTTP requests and native pixels per job."""

    def __init__(
        self,
        maximum_bytes=64 * 1024 * 1024,
        maximum_requests=128,
        maximum_pixels=20_000_000,
        seconds=25,
    ):
        self.maximum_bytes = maximum_bytes
        self.maximum_requests = maximum_requests
        self.maximum_pixels = maximum_pixels
        self.deadline = time.monotonic() + seconds
        self.downloaded_bytes = 0
        self.requests = 0
        self.pixels = 0
        self.cache_bytes = 0

    def check(self, byte_count=0, pixels=0, request=False):
        if time.monotonic() >= self.deadline:
            raise TerrainError("Terrain execution time limit reached")
        if self.downloaded_bytes + byte_count > self.maximum_bytes:
            raise TerrainError("Terrain download byte limit reached; shorten the route")
        if self.requests + int(request) > self.maximum_requests:
            raise TerrainError(
                "Terrain upstream request limit reached; shorten the route"
            )
        if self.pixels + pixels > self.maximum_pixels:
            raise TerrainError(
                "Terrain native-pixel limit reached; narrow the corridor"
            )
        self.downloaded_bytes += byte_count
        self.requests += int(request)
        self.pixels += pixels

    def statistics(self):
        return {
            "downloaded_bytes": self.downloaded_bytes,
            "http_requests": self.requests,
            "cached_bytes_read": self.cache_bytes,
            "native_pixels_read": self.pixels,
        }


class RangeCache:
    """Store bounded immutable blocks; the worker holds the directory's job lock."""

    def __init__(self, directory: Path, maximum_bytes=512 * 1024 * 1024):
        self.directory = directory
        self.maximum_bytes = maximum_bytes
        directory.mkdir(parents=True, exist_ok=True)

    def path(self, key):
        return self.directory / (hashlib.sha256(key.encode()).hexdigest() + ".block")

    def get(self, key):
        path = self.path(key)
        try:
            data = path.read_bytes()
            os.utime(path, None)
            return data
        except FileNotFoundError:
            return None

    def size(self):
        return sum(path.stat().st_size for path in self.directory.glob("*.block"))

    def put(self, key, data):
        if len(data) > self.maximum_bytes:
            return
        entries = sorted(
            (p.stat().st_mtime_ns, p, p.stat().st_size)
            for p in self.directory.glob("*.block")
        )
        total = sum(size for _, _, size in entries)
        while entries and total + len(data) > self.maximum_bytes:
            _, path, size = entries.pop(0)
            path.unlink(missing_ok=True)
            total -= size
        with tempfile.NamedTemporaryFile(
            dir=self.directory, delete=False, prefix="pending-"
        ) as stream:
            temporary = Path(stream.name)
            try:
                stream.write(data)
                stream.close()
                temporary.replace(self.path(key))
            finally:
                temporary.unlink(missing_ok=True)


class RangeFile(io.RawIOBase):
    """Expose a version-pinned remote object as a seekable GDAL input."""

    block_size = 1024 * 1024

    def __init__(self, url, cache, budget):
        super().__init__()
        self.url, self.cache, self.budget = url, cache, budget
        self.position = 0
        self.failure = None
        parsed = urlsplit(url)
        self.remote_path = parsed.path
        self.connection = (
            http.client.HTTPSConnection(
                parsed.hostname,
                parsed.port,
                timeout=5,
                context=ssl.create_default_context(cafile=certifi.where()),
            )
            if parsed.scheme == "https"
            else http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=5)
        )
        budget.check(request=True)
        try:
            self.connection.request("HEAD", self.remote_path)
            with self.connection.getresponse() as response:
                if response.status != 200:
                    raise TerrainError("Terrain source metadata unavailable")
                self.length = int(response.headers["Content-Length"])
                self.etag = response.headers.get("ETag")
                response.read()
            if (
                not self.etag
                or self.etag.startswith("W/")
                or not 0 < self.length <= 128 * 1024 * 1024
            ):
                raise TerrainError(
                    "Terrain object lacks a bounded size or strong version identifier"
                )
        except (OSError, ValueError, TypeError, http.client.HTTPException) as error:
            self.connection.close()
            raise TerrainError("Terrain source metadata unavailable") from error

    def close(self):
        self.connection.close()
        super().close()

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        position = offset + (
            self.position
            if whence == io.SEEK_CUR
            else self.length
            if whence == io.SEEK_END
            else 0
        )
        if position < 0 or whence not in (io.SEEK_SET, io.SEEK_CUR, io.SEEK_END):
            raise ValueError("Invalid terrain file seek")
        self.position = position
        return position

    def read(self, size=-1):
        try:
            self.budget.check()
            end = self.length if size < 0 else min(self.length, self.position + size)
            output = bytearray()
            while self.position < end:
                first = self.position // self.block_size * self.block_size
                last = min(self.length, first + self.block_size) - 1
                data = self.block(first, last)
                count = min(end - self.position, last + 1 - self.position)
                offset = self.position - first
                output.extend(data[offset : offset + count])
                self.position += count
            return bytes(output)
        except TerrainError as error:
            self.failure = error
            raise

    def readinto(self, buffer):
        data = self.read(len(buffer))
        buffer[: len(data)] = data
        return len(data)

    def block(self, first, last):
        key = f"{self.url}\n{self.etag}\n{first}\n{last}"
        data = self.cache.get(key)
        if data is not None and len(data) == last - first + 1:
            self.budget.cache_bytes += len(data)
            return data
        self.budget.check(byte_count=last - first + 1, request=True)
        try:
            self.connection.request(
                "GET",
                self.remote_path,
                headers={
                    "Range": f"bytes={first}-{last}",
                    "If-Match": self.etag,
                    "Accept-Encoding": "identity",
                },
            )
            with self.connection.getresponse() as response:
                if (
                    response.status != 206
                    or response.headers.get("ETag") != self.etag
                    or response.headers.get("Content-Range")
                    != f"bytes {first}-{last}/{self.length}"
                ):
                    raise TerrainError(
                        "Terrain source changed or did not honor the byte range"
                    )
                data = response.read(last - first + 2)
                if len(data) != last - first + 1:
                    raise TerrainError(
                        "Terrain source returned an incomplete byte range"
                    )
        except (OSError, http.client.HTTPException) as error:
            self.connection.close()
            raise TerrainError(
                "Terrain byte range unavailable or source version changed"
            ) from error
        self.cache.put(key, data)
        return data
