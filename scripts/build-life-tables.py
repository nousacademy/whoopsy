#!/usr/bin/env python3
"""Build `Data/Resources/LifeTables/lifeTables.json` from the published sources.

Run by hand, never by the app or the suite: the output is a committed resource, and the numbers in it
are somebody else's publication rather than anything this app computes. Re-running with the same source
edition must produce a byte-identical file, which is why the values are rounded to six significant
figures and the keys are sorted.

**The US table is NCHS's own spreadsheet**, linked from the report it accompanies —
`United States Life Tables, 2024`, NVSR 75(05), Tables 1–3 (total, male, female), which carry `q_x` by
single year of age 0 to 100-and-over. The XLSX is the source of record here rather than the PDF: the
PDF's columns are laid out for reading, the spreadsheet's for parsing.

Usage:  python3 scripts/build-life-tables.py [--check]

`--check` regenerates into a temporary file and diffs it against the committed one, which is the shape
a CI gate would take if this resource ever needs one.
"""

import io
import json
import os
import re
import sys
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

USA_TABLES = {
    "total": "Table01",
    "male": "Table02",
    "female": "Table03",
}
USA_URL = "https://ftp.cdc.gov/pub/Health_Statistics/NCHS/Publications/NVSR/75-05/{name}.xlsx"
USA_CITATION = (
    "NCHS, United States Life Tables, 2024 (NVSR 75-05), Tables 1-3"
)
USA_REPORT_URL = "https://www.cdc.gov/nchs/data/nvsr/nvsr75/nvsr75-05.pdf"

OUTPUT = os.path.join(
    os.path.dirname(__file__),
    "..", "ios", "Sources", "Whoopsy", "Data", "Resources", "LifeTables", "lifeTables.json",
)


def sheet_rows(blob: bytes):
    archive = zipfile.ZipFile(io.BytesIO(blob))
    shared = []
    if "xl/sharedStrings.xml" in archive.namelist():
        root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
        for item in root.findall("m:si", {"m": NS[1:-1]}):
            shared.append("".join(t.text or "" for t in item.iter(NS + "t")))

    sheet = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
    for row in sheet.iter(NS + "row"):
        cells = {}
        for cell in row.iter(NS + "c"):
            column = re.match(r"[A-Z]+", cell.get("r")).group(0)
            value = cell.find(NS + "v")
            text = value.text if value is not None else None
            if cell.get("t") == "s" and text is not None:
                text = shared[int(text)]
            cells[column] = text
        yield cells


def series(blob: bytes):
    """The `q_x` and `e_x` columns, age 0 to 100-and-over, in table order.

    Both are taken from the publication rather than one derived from the other: `q_x` is what the
    risk adjustment acts on, and the published `e_x` is what the app checks its own integration
    against — a table whose recomputed expectancy disagreed with the printed one would be a parser bug
    that no screenshot could show.
    """
    qx_values = []
    ex_values = []
    for cells in sheet_rows(blob):
        label = cells.get("A") or ""
        if not re.match(r"^\d", label):
            continue
        qx, ex = cells.get("B"), cells.get("G")
        if qx is None or ex is None:
            raise SystemExit(f"row {label!r} is missing q_x or e_x")
        qx_values.append(float(qx))
        ex_values.append(float(ex))
    if len(qx_values) != 101:
        raise SystemExit(f"expected 101 age rows, got {len(qx_values)}")
    if not qx_values[-1] == 1.0:
        raise SystemExit(f"the terminal q_x should be 1.0, got {qx_values[-1]}")
    return (
        [float(f"{value:.6g}") for value in qx_values],
        [float(f"{value:.6g}") for value in ex_values],
    )


def build():
    sexes = {}
    for name, table in USA_TABLES.items():
        url = USA_URL.format(name=table)
        with urllib.request.urlopen(url, timeout=60) as response:
            qx, ex = series(response.read())
            sexes[name] = {"qx": qx, "ex": ex}
    return {
        "retrieved": "2026-10-29",
        "tables": {
            "USA": {
                "source": USA_CITATION,
                "sourceURL": USA_REPORT_URL,
                "year": 2024,
                "sexes": sexes,
            },
        },
    }


def main():
    document = build()
    rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if "--check" in sys.argv:
        with open(OUTPUT) as handle:
            committed = handle.read()
        if committed != rendered:
            raise SystemExit("lifeTables.json is stale — re-run without --check")
        print("lifeTables.json is current")
        return
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w") as handle:
        handle.write(rendered)
    print(f"wrote {os.path.relpath(OUTPUT)}")


if __name__ == "__main__":
    main()
