import contextlib
import io
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import numpy as np
from rasterio.io import MemoryFile
from rasterio.transform import from_origin

from range_cache import Budget, RangeCache, RangeFile, TerrainError
from worker import analyze_tile, run_job


@contextlib.contextmanager
def source_server(data):
    state = {"gets": 0, "etag": '"v1"', "ranges": [], "ignore_range": False}

    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("ETag", state["etag"])
            self.end_headers()

        def do_GET(self):
            state["gets"] += 1
            if self.headers.get("If-Match") != state["etag"]:
                self.send_response(412)
                self.end_headers()
                return
            first, last = map(int, self.headers["Range"][6:].split("-"))
            state["ranges"].append((first, last))
            payload = data[first : last + 1]
            self.send_response(200 if state["ignore_range"] else 206)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Range", f"bytes {first}-{last}/{len(data)}")
            self.send_header("ETag", state["etag"])
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/tile.tif", state
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class TerrainReads(unittest.TestCase):
    def test_reads_only_ranges_and_reuses_disk_cache_across_readers(self):
        data = bytes(range(256)) * 16384
        with (
            tempfile.TemporaryDirectory() as directory,
            source_server(data) as (url, state),
        ):
            for _ in range(2):
                cache = RangeCache(Path(directory), maximum_bytes=2 * 1024 * 1024)
                with RangeFile(url, cache, Budget()) as source:
                    source.seek(100)
                    self.assertEqual(source.read(30), data[100:130])
                    source.seek(-10, io.SEEK_END)
                    self.assertEqual(source.read(), data[-10:])
                self.assertLessEqual(cache.size(), 2 * 1024 * 1024)
            self.assertEqual(state["gets"], 2)
            self.assertTrue(
                all(last - first + 1 < len(data) for first, last in state["ranges"])
            )

    def test_changed_sources_and_ignored_ranges_do_not_reuse_old_bytes(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            source_server(b"x" * 2000) as (url, state),
        ):
            cache = RangeCache(Path(directory), maximum_bytes=4096)
            with RangeFile(url, cache, Budget()) as source:
                state["etag"] = '"v2"'
                with self.assertRaises(TerrainError):
                    source.read(1)
            state["ignore_range"] = True
            with (
                RangeFile(url, cache, Budget()) as source,
                self.assertRaises(TerrainError),
            ):
                source.read(1)
            self.assertEqual(cache.size(), 0)

    def test_budget_and_eviction_bound_downloads_and_cache(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            source_server(b"x" * 2000) as (url, _),
        ):
            cache = RangeCache(Path(directory), maximum_bytes=20)
            cache.put("a", b"a" * 15)
            cache.put("b", b"b" * 15)
            self.assertLessEqual(cache.size(), 20)
            smaller = RangeCache(Path(directory), maximum_bytes=10)
            self.assertLessEqual(smaller.size(), 10)
            with (
                RangeFile(url, cache, Budget(maximum_bytes=100)) as source,
                self.assertRaises(TerrainError),
            ):
                source.read(1)

    def test_native_peak_nodata_and_climb_bound_survive_window_selection(self):
        samples = np.full((1200, 1200), 10, dtype="float32")
        samples[7, 7] = 1000
        samples[8, 7] = -9999
        with MemoryFile() as memory:
            with memory.open(
                driver="GTiff",
                width=1200,
                height=1200,
                count=1,
                dtype="float32",
                transform=from_origin(
                    -123 - 1 / 2400, 38 + 1 / 2400, 1 / 1200, 1 / 1200
                ),
                crs="EPSG:4326",
                nodata=-9999,
                tiled=True,
                blockxsize=128,
                blockysize=128,
                compress="deflate",
            ) as dataset:
                dataset.write(samples, 1)
            payload = memory.read()
        geometry = {
            "type": "Polygon",
            "coordinates": [
                [
                    [-123 - 1 / 2400, 38 + 1 / 2400],
                    [-122 - 1 / 2400, 38 + 1 / 2400],
                    [-122 - 1 / 2400, 37 + 1 / 2400],
                    [-123 - 1 / 2400, 37 + 1 / 2400],
                    [-123 - 1 / 2400, 38 + 1 / 2400],
                ]
            ],
        }
        climb = {
            "starting_altitude_ft": 100,
            "gradient_ft_per_nm": 200,
            "clearance_ft": 50,
            "start": [-123, 38],
            "half_width_m": 1852,
        }
        with (
            tempfile.TemporaryDirectory() as directory,
            source_server(payload) as (url, _),
        ):
            cache = RangeCache(Path(directory), maximum_bytes=1024 * 1024)
            result = analyze_tile(url, geometry, cache, Budget(), climb)
            self.assertEqual(result["maximum"]["elevation_m"], 1000)
            self.assertEqual(result["nodata_cells"], 1)
            self.assertEqual(result["valid_cells"], 1200 * 1200 - 1)
            self.assertLess(result["climb"]["minimum_margin_ft"], 0)
            self.assertAlmostEqual(result["maximum"]["longitude"], -123 + 7 / 1200)
            request = {
                "start": [-123, 38],
                "half_width_m": 1852,
                "climb": dict(climb, starting_altitude_ft=10000),
                "tiles": [
                    {
                        "name": "Copernicus_DSM_COG_30_N37_00_W123_00_DEM",
                        "product": "glo90",
                        "geometry": geometry,
                    }
                ],
            }
            with patch("worker.tile_url", return_value=url):
                combined = run_job(request, cache, Budget())
            self.assertFalse(combined["coverage"]["complete"])
            self.assertEqual(combined["climb"]["status"], "not_established")
            self.assertGreater(combined["climb"]["limiting"]["minimum_margin_ft"], 0)

    def test_shifted_or_cropped_land_cannot_become_complete_ocean(self):
        with MemoryFile() as memory:
            with memory.open(
                driver="GTiff",
                width=32,
                height=32,
                count=1,
                dtype="float32",
                transform=from_origin(10, 10, 0.001, 0.001),
                crs="EPSG:4326",
            ) as dataset:
                dataset.write(np.full((32, 32), 9000, dtype="float32"), 1)
            payload = memory.read()
        geometry = {
            "type": "Polygon",
            "coordinates": [
                [[-123, 38], [-122.99, 38], [-122.99, 37.99], [-123, 37.99], [-123, 38]]
            ],
        }
        request = {
            "start": [-123, 38],
            "half_width_m": 1852,
            "climb": {
                "starting_altitude_ft": 100,
                "gradient_ft_per_nm": 200,
                "clearance_ft": 50,
            },
            "tiles": [
                {
                    "name": "Copernicus_DSM_COG_30_N37_00_W123_00_DEM",
                    "product": "glo90",
                    "geometry": geometry,
                },
                {"name": "ocean", "product": "ocean", "geometry": geometry},
            ],
        }
        with (
            tempfile.TemporaryDirectory() as directory,
            source_server(payload) as (url, _),
            patch("worker.tile_url", return_value=url),
        ):
            result = run_job(request, RangeCache(Path(directory)), Budget())
            self.assertFalse(result["coverage"]["complete"])
            self.assertEqual(len(result["coverage"]["gaps"]), 1)
            self.assertEqual(result["climb"]["status"], "not_established")


if __name__ == "__main__":
    unittest.main()
