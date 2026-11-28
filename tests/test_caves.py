"""Headless regressions for cave mouths, chunk seams, and walking.

Run with ``uv run python -m unittest discover -s tests -v``. The Scheme
libraries compile into a temporary directory; no window or audio is opened.
"""

from collections import Counter
from functools import lru_cache
import math
from pathlib import Path
import sys
import tempfile
import unittest

from hissp_scheme import core_library_files
from hissp_scheme.reader import transpile_scheme_file


ROOT = Path(__file__).resolve().parents[1]
SITES = ((-4, 3), (-3, 2), (-1, -4), (0, -1), (0, 3), (2, 2), (3, -2), (0, 4))


def scheme_values(pair):
    """Return the elements of a proper Scheme list as a Python list."""
    result = []
    while hasattr(pair, "car"):
        result.append(pair.car)
        pair = pair.cdr
    return result


class CaveTests(unittest.TestCase):
    """Check the seed-4242 caves used in the visual handoff."""

    @classmethod
    def setUpClass(cls):
        """Load only the engine-independent world libraries."""
        cls.build = tempfile.TemporaryDirectory(prefix="hissp-cave-tests-")
        sys.path.insert(0, cls.build.name)
        sources = (ROOT / "src" / f"world_{name}.sld" for name in ("state", "terrain", "caves"))
        for source in (*core_library_files(), *sources):
            transpile_scheme_file(source, output_dir=cls.build.name)
        cls.terrain = sys.modules["world_terrain"]
        cls.caves = sys.modules["world_caves"]
        cls.terrain.setQzH_worldQzH_seedQzBANG_(4242)
        cls.size = cls.terrain.CHUNKQzH_SIZE

    @classmethod
    def tearDownClass(cls):
        """Release mesh buffers and the generated modules' directory."""
        cls.mesh.cache_clear()
        sys.path.remove(cls.build.name)
        cls.build.cleanup()

    @classmethod
    @lru_cache(maxsize=None)
    def mesh(cls, cx, cz):
        """Return flat mesh buffers for one chunk, including its cave surface.

        Args:
            cx: Chunk coordinate along x.
            cz: Chunk coordinate along z.

        Returns:
            Vertices, normals, triangle indices, and whether the chunk has caves.
        """
        ox, oz = cx * cls.size, cz * cls.size
        data = scheme_values(cls.terrain.chunkQzH_meshQzH_data(
            ox, oz, lambda: None,
            lambda heights, colors, normals: cls.caves.caveQzH_chunkQzH_data(
                ox, oz, heights, colors, normals, lambda: None),
        ))
        if data[5] is not False:
            cave = scheme_values(data[5])
            return cave[0], cave[1], cave[4], True
        return data[0], data[1], data[2], False

    def test_open_mouth_has_no_zero_thickness_sheet(self):
        """Coincident cave and terrain surfaces must remain open on both sides."""
        cave = self.caves
        context = [
            [cave.capsule(-2.0, 19.0, 0.0, 4.0, 19.0, 0.0, 2.0)],
            cave.list([0.0, 18.0, 0.0, 1.0, 0.0]),
        ]
        for y in (17.98, 18.0, 18.02):
            with self.subTest(y=y):
                self.assertGreater(cave.solidQzH_field(context, 0.0, y, 0.0, 18.0), 0.0)

    def test_meshes_are_watertight_and_consistently_wound(self):
        """Weld whole cave regions and check internal edges and triangle normals."""
        for site in SITES:
            with self.subTest(site=site):
                cave = self.caves.siteQzH_cave(*site)
                self.assertIsNot(cave, False)
                x0, z0, x1, z1 = scheme_values(cave[3])
                c0x, c1x = math.floor(x0 / self.size) - 1, math.floor(x1 / self.size) + 1
                c0z, c1z = math.floor(z0 / self.size) - 1, math.floor(z1 / self.size) + 1
                edges = Counter()
                flipped = []
                for cx in range(c0x - 1, c1x + 2):
                    for cz in range(c0z - 1, c1z + 2):
                        vertices, normals, triangles, has_cave = self.mesh(cx, cz)
                        points = [
                            (round(vertices[i] + cx * self.size, 6),
                             round(vertices[i + 1], 6),
                             round(vertices[i + 2] + cz * self.size, 6))
                            for i in range(0, len(vertices), 3)
                        ]
                        for t in range(0, len(triangles), 3):
                            ids = triangles[t:t + 3]
                            a, b, c = (points[i] for i in ids)
                            if len({a, b, c}) < 3:
                                continue
                            edges.update(((a, b), (b, c), (c, a)))
                            if not has_cave or not (c0x <= cx <= c1x and c0z <= cz <= c1z):
                                continue
                            if all(abs(p[0] - round(p[0])) < 1e-6 and
                                   abs(p[2] - round(p[2])) < 1e-6 for p in (a, b, c)):
                                continue
                            u = tuple(b[k] - a[k] for k in range(3))
                            v = tuple(c[k] - a[k] for k in range(3))
                            cross = (u[1]*v[2] - u[2]*v[1], u[2]*v[0] - u[0]*v[2], u[0]*v[1] - u[1]*v[0])
                            normal = tuple(sum(normals[3*i + k] for i in ids) for k in range(3))
                            if sum(cross[k] * normal[k] for k in range(3)) > 1e-9:
                                flipped.append((a, b, c))

                def inside(point):
                    """Exclude the external boundary of the sampled region."""
                    return (c0x*self.size + 2 < point[0] < (c1x + 1)*self.size - 2 and
                            c0z*self.size + 2 < point[2] < (c1z + 1)*self.size - 2)

                bad_edges = [(a, b, count, edges[(b, a)]) for (a, b), count in edges.items()
                             if inside(a) and inside(b) and (count != 1 or edges[(b, a)] != 1)]
                self.assertFalse(bad_edges, f"{len(bad_edges)} open/repeated edges; first: {bad_edges[:2]}")
                self.assertFalse(flipped, f"{len(flipped)} flipped faces; first: {flipped[:2]}")

    def ground(self, x, z, feet):
        """Return the walkable floor selected from the current foot height."""
        height = self.terrain.terrainQzH_height(x, z)
        floor = self.caves.caveQzH_ground(x, z, feet, height)
        return (height if floor is False else floor), height

    def can_step(self, x, z, feet, distance):
        """Apply the game's climb and cave headroom limits to a candidate step."""
        floor, height = self.ground(x, z, feet)
        allowed = (floor <= feet + 0.01 + 2.0 * distance and
                   self.caves.caveQzH_headroomQzQUERY_(x, z, floor, height))
        return allowed, floor

    def test_every_mouth_can_be_entered_and_exited(self):
        """Walk from six metres outside each opening to inside, and back."""
        for site in SITES:
            cave = self.caves.siteQzH_cave(*site)
            for mx, my, mz, dx, dz in scheme_values(cave[2]):
                self.caves.cavesQzH_readyQzH_nearQzBANG_(mx, mz)
                for direction in (1, -1):
                    with self.subTest(site=site, direction=direction, mouth=(mx, mz)):
                        along = -6.0 if direction > 0 else 4.5
                        x, z = mx + along*dx, mz + along*dz
                        hint = my if direction < 0 else self.terrain.terrainQzH_height(x, z)
                        feet, _ = self.ground(x, z, hint + 0.5)
                        for _ in range(50):
                            if (direction > 0 and along >= 4.5) or (direction < 0 and along <= -6.0):
                                break
                            next_along = along + direction*0.25
                            for side in (0.0, 0.4, -0.4, 0.8, -0.8, 1.2, -1.2):
                                nx = mx + next_along*dx - side*dz*0.25
                                nz = mz + next_along*dz + side*dx*0.25
                                allowed, floor = self.can_step(nx, nz, feet, math.hypot(nx - x, nz - z))
                                if allowed:
                                    x, z, feet, along = nx, nz, floor, next_along
                                    break
                            else:
                                self.fail(f"Blocked {along:.2f} m along the mouth at {site}")
                        else:
                            self.fail(f"Did not finish walking through the mouth at {site}")

    def test_main_tunnels_are_walkable(self):
        """Follow each main tunnel's centre line, including its first chamber."""
        for site in SITES:
            with self.subTest(site=site):
                cave = self.caves.siteQzH_cave(*site)
                path = []
                for index, primitive in enumerate(cave[0]):
                    if primitive[0] != 0:
                        break
                    if index and (abs(primitive[1] - cave[0][index - 1][4]) > 1e-6 or
                                  abs(primitive[3] - cave[0][index - 1][6]) > 1e-6):
                        break
                    if not index:
                        path.append((primitive[1], primitive[3]))
                    path.append((primitive[4], primitive[6]))
                x, z = path[0]
                self.caves.cavesQzH_readyQzH_nearQzBANG_(x, z)
                feet = self.terrain.terrainQzH_height(x, z)
                for segment, (tx, tz) in enumerate(path[1:], 1):
                    for _ in range(400):
                        distance = math.hypot(tx - x, tz - z)
                        if distance <= 0.4:
                            break
                        ux, uz = (tx - x)/distance, (tz - z)/distance
                        for side in (0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.0, -2.0):
                            angle = side*0.6
                            vx = ux*math.cos(angle) - uz*math.sin(angle)
                            vz = ux*math.sin(angle) + uz*math.cos(angle)
                            nx, nz = x + 0.25*vx, z + 0.25*vz
                            allowed, floor = self.can_step(nx, nz, feet, 0.25)
                            if allowed:
                                x, z, feet = nx, nz, floor
                                break
                        else:
                            self.fail(f"Blocked at segment {segment} in cave {site}: {(x, feet, z)}")
                    else:
                        self.fail(f"Could not reach segment {segment} in cave {site}")


if __name__ == "__main__":
    unittest.main()
