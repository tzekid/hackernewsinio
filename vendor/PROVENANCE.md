# Authentication dependency snapshots

These are the exact libraries previously selected in `build.zig.zon`.
Library sources are unchanged; licensing files are retained.

- Passcay 3.1.0: https://github.com/tzekid/passcay at
  `90ab8576a69baba0779583a716fca4c39d3561c8`, package hash
  `passcay-3.1.0-ckLGcnwzBAA-QYZDDPzodVmJwdzLMEKcEsk2Z4ltGNCv`.
  Its Zbor dependency now uses the sibling snapshot.
- Zbor 0.21.2: https://codeberg.org/r4gus/zbor at
  `658c1c0ec607557b52d2e2a42acbfad31058ecee`, package hash
  `zbor-0.21.2-kr-CoPF7AwAU2EqWqJzgxd1jHhpaaRBK0_c1LCgiwTbn`.
  Its build script supplies the existing debug default when Zig 0.18's
  `standardOptimizeOption` returns null.

See `passcay/LICENSE` and `zbor/license` for their MIT licenses.
