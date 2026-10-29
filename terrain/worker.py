"""Read native Copernicus cells through a bounded range cache for one MCP job."""

import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
import re
import resource
import signal
import sys
import time
from pathlib import Path

import numpy as np
import rasterio
from pyproj import Geod
from rasterio.features import bounds, geometry_mask
from rasterio.windows import from_bounds, intersect

from range_cache import Budget, RangeCache, RangeFile, TerrainError

READER_REVISION = "copernicus-native-1"
GEOD = Geod(ellps="WGS84")


def climb_margin(values, rows, columns, transform, climb):
    """Bound flight distance below using radial distance minus corridor/cell reach."""
    longitudes = transform.c + (columns + 0.5) * transform.a
    latitudes = transform.f + (rows + 0.5) * transform.e
    start_lon, start_lat = climb["start"]
    _, _, radial = GEOD.inv(
        np.full(values.size, start_lon),
        np.full(values.size, start_lat),
        longitudes,
        latitudes,
    )
    cell_radius = 112000 * math.hypot(transform.a, transform.e) / 2
    distances = np.maximum(0, radial - climb["half_width_m"] - cell_radius) / 1852
    margins = (
        climb["starting_altitude_ft"]
        + climb["gradient_ft_per_nm"] * distances
        - values / 0.3048
        - climb["clearance_ft"]
    )
    index = int(np.argmin(margins))
    return {
        "minimum_margin_ft": float(margins[index]),
        "distance_lower_bound_nm": float(distances[index]),
        "longitude": float(longitudes[index]),
        "latitude": float(latitudes[index]),
    }


def analyze_tile(url, geometry, cache, budget, climb=None):
    """Find all selected native-cell extrema without using averaged overviews."""
    handles = []

    def opener(path, mode="rb"):
        if path != "terrain.tif" or mode not in ("r", "rb"):
            raise FileNotFoundError(path)
        handle = RangeFile(url, cache, budget)
        handles.append(handle)
        return handle

    result = {"maximum": None, "valid_cells": 0, "nodata_cells": 0, "climb": None}
    try:
        with (
            rasterio.Env(
                GDAL_CACHEMAX=32 * 1024 * 1024,
                GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
                GDAL_PAM_ENABLED="NO",
            ),
            rasterio.open("terrain.tif", opener=opener, driver="GTiff") as source,
        ):
            if (
                source.count != 1
                or source.crs != rasterio.CRS.from_epsg(4326)
                or source.width > 3600
                or source.height > 3600
                or source.transform.b != 0
                or source.transform.d != 0
                or source.transform.a <= 0
                or source.transform.e >= 0
            ):
                raise TerrainError("Unsupported terrain raster grid")
            extent = from_bounds(*bounds(geometry), transform=source.transform)
            for _, window in source.block_windows(1):
                budget.check()
                if not intersect(window, extent):
                    continue
                transform = source.window_transform(window)
                shape = (int(window.height), int(window.width))
                selected = geometry_mask(
                    [geometry],
                    out_shape=shape,
                    transform=transform,
                    all_touched=True,
                    invert=True,
                )
                if not selected.any():
                    continue
                budget.check(pixels=shape[0] * shape[1])
                samples = source.read(1, window=window, masked=True)
                valid = (
                    selected & ~np.ma.getmaskarray(samples) & np.isfinite(samples.data)
                )
                result["nodata_cells"] += int(np.count_nonzero(selected & ~valid))
                result["valid_cells"] += int(np.count_nonzero(valid))
                if not valid.any():
                    continue
                rows, columns = np.nonzero(valid)
                values = samples.data[valid]
                index = int(np.argmax(values))
                maximum = {
                    "elevation_m": float(values[index]),
                    "longitude": float(
                        transform.c + (columns[index] + 0.5) * transform.a
                    ),
                    "latitude": float(transform.f + (rows[index] + 0.5) * transform.e),
                }
                if (
                    result["maximum"] is None
                    or maximum["elevation_m"] > result["maximum"]["elevation_m"]
                ):
                    result["maximum"] = maximum
                if climb:
                    margin = climb_margin(values, rows, columns, transform, climb)
                    if (
                        result["climb"] is None
                        or margin["minimum_margin_ft"]
                        < result["climb"]["minimum_margin_ft"]
                    ):
                        result["climb"] = margin
            result["resolution_arc_seconds"] = [
                source.transform.a * 3600,
                -source.transform.e * 3600,
            ]
        if not handles or len({handle.etag for handle in handles}) != 1:
            raise TerrainError("Terrain source version changed during reading")
        result["etag"] = handles[0].etag
        result["retrieved_at"] = datetime.datetime.now(datetime.UTC).isoformat()
        return result
    except Exception as error:
        failure = next((handle.failure for handle in handles if handle.failure), None)
        if failure:
            raise failure from error
        if isinstance(error, TerrainError):
            raise
        raise TerrainError("Terrain raster could not be read") from error
    finally:
        for handle in handles:
            handle.close()


def tile_url(tile):
    """Construct only public Copernicus URLs from validated catalog identifiers."""
    product, name = tile["product"], tile["name"]
    if product not in ("glo30", "glo90") or not re.fullmatch(
        r"Copernicus_DSM_COG_(10|30)_[NS]\d{2}_00_[EW]\d{3}_00_DEM", name
    ):
        raise TerrainError("Invalid catalog tile")
    bucket = "30m" if product == "glo30" else "90m"
    return f"https://copernicus-dem-{bucket}.s3.amazonaws.com/{name}/{name}.tif"


def run_job(request, cache, budget):
    """Combine tile results while preserving failures and unknown native cells."""
    maximum = None
    sources, gaps = [], []
    valid_cells = nodata_cells = ocean_tiles = 0
    limiting = None
    climb = request.get("climb")
    if climb:
        climb = dict(
            climb, start=request["start"], half_width_m=request["half_width_m"]
        )
    if not 1 <= len(request["tiles"]) <= 32:
        raise TerrainError("Terrain tile limit reached; shorten the route")
    for tile in request["tiles"]:
        budget.check()
        if tile["product"] == "ocean":
            ocean_tiles += 1
            candidate = {"elevation_m": 0, "location": "catalog_classified_ocean"}
            if maximum is None or maximum["elevation_m"] < 0:
                maximum = candidate
            if climb:
                margin = {
                    "minimum_margin_ft": climb["starting_altitude_ft"]
                    - climb["clearance_ft"],
                    "distance_lower_bound_nm": 0,
                    "location": "catalog_classified_ocean",
                }
                if (
                    limiting is None
                    or margin["minimum_margin_ft"] < limiting["minimum_margin_ft"]
                ):
                    limiting = margin
            continue
        try:
            result = analyze_tile(
                tile_url(tile), tile["geometry"], cache, budget, climb
            )
            sources.append(
                {
                    "tile": tile["name"],
                    "product": tile["product"],
                    "etag": result["etag"],
                    "retrieved_at": result["retrieved_at"],
                    "resolution_arc_seconds": result["resolution_arc_seconds"],
                }
            )
            valid_cells += result["valid_cells"]
            nodata_cells += result["nodata_cells"]
            candidate = result["maximum"]
            if candidate is not None and (
                maximum is None or candidate["elevation_m"] > maximum["elevation_m"]
            ):
                maximum = dict(candidate, tile=tile["name"])
            if result["climb"] and (
                limiting is None
                or result["climb"]["minimum_margin_ft"] < limiting["minimum_margin_ft"]
            ):
                limiting = result["climb"]
        except TerrainError as error:
            gaps.append({"tile": tile["name"], "reason": str(error)})
    complete = not gaps and nodata_cells == 0 and maximum is not None
    if maximum is not None:
        maximum["elevation_ft"] = maximum["elevation_m"] / 0.3048
    result = {
        "maximum": maximum,
        "coverage": {
            "complete": complete,
            "valid_cells": valid_cells,
            "nodata_cells": nodata_cells,
            "ocean_tiles": ocean_tiles,
            "gaps": gaps,
        },
        "tiles": sources,
        "usage": budget.statistics(),
        "reader_revision": READER_REVISION,
        "vertical_datum": "EGM2008",
        "answer_cache_hit": False,
    }
    if climb:
        result["climb"] = {
            "scope": "terrain_surface_only",
            "method": "conservative_radial_distance_bound",
            "status": "conditional_clearance_met"
            if complete and limiting is not None and limiting["minimum_margin_ft"] >= 0
            else "not_established",
            "limiting": limiting,
            "assumptions": climb,
        }
    return result


def main():
    """Execute one bounded request with exclusive local-cache ownership."""
    if sys.platform == "linux":
        resource.setrlimit(resource.RLIMIT_AS, (1024 * 1024 * 1024, 1024 * 1024 * 1024))
    parser = argparse.ArgumentParser()
    parser.add_argument("request")
    parser.add_argument("response")
    parser.add_argument("cache")
    parser.add_argument("--cache-bytes", type=int, default=512 * 1024 * 1024)
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, lambda *_: os._exit(124))
    signal.alarm(27)
    directory = Path(args.cache)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "worker.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise TerrainError("Terrain worker is busy; retry shortly") from None
        for pending in directory.glob("pending-*"):
            pending.unlink(missing_ok=True)
        request_data = Path(args.request).read_bytes()
        if len(request_data) > 2 * 1024 * 1024:
            raise TerrainError("Terrain request geometry is too large")
        request = json.loads(request_data)
        cache = RangeCache(directory, args.cache_bytes)
        key = (
            "answer:" + READER_REVISION + ":" + hashlib.sha256(request_data).hexdigest()
        )
        cached = cache.get(key)
        response = None
        if cached:
            stored = json.loads(cached)
            if time.time() - stored["time"] < 300:
                response = stored["result"]
                response["answer_cache_hit"] = True
                response["usage"] = Budget().statistics()
        if response is None:
            response = run_job(request, cache, Budget())
            if response["coverage"]["complete"]:
                cache.put(
                    key,
                    json.dumps(
                        {"time": time.time(), "result": response}, allow_nan=False
                    ).encode(),
                )
        Path(args.response).write_text(json.dumps(response, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (TerrainError, OSError, ValueError, MemoryError) as error:
        raise SystemExit(str(error)) from error
