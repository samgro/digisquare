import { describe, expect, it } from "vitest";
import { decodeWkbHex } from "./wkb.js";

describe("decodeWkbHex", () => {
  it("decodes the little-endian point Overture stores for a place", () => {
    // Blue Bottle Coffee at 151 3rd St, straight from the 2026-09-23 release.
    const geometry = decodeWkbHex("0101000000aa2833809e995ec05de2d594a5e44240");
    expect(geometry.type).toBe("Point");
    if (geometry.type !== "Point") return;
    expect(geometry.coordinates[0]).toBeCloseTo(-122.4003, 4);
    expect(geometry.coordinates[1]).toBeCloseTo(37.7863, 4);
  });

  it("decodes a polygon with a hole", () => {
    // Square 0..10 with a square hole 4..6, little-endian.
    const ring = (points: [number, number][]) =>
      points.map(([x, y]) => float(x) + float(y)).join("");
    const outer = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]] as [number, number][];
    const hole = [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]] as [number, number][];
    const hex = "01" + "03000000" + "02000000" + "05000000" + ring(outer) + "05000000" + ring(hole);
    const geometry = decodeWkbHex(hex);
    expect(geometry).toEqual({ type: "Polygon", coordinates: [outer, hole] });
  });

  it("decodes a big-endian multipolygon", () => {
    const point = (x: number, y: number) => floatBigEndian(x) + floatBigEndian(y);
    const triangle = "00" + "00000003" + "00000001" + "00000003" + point(0, 0) + point(1, 0) + point(0, 1);
    const hex = "00" + "00000006" + "00000001" + triangle;
    const geometry = decodeWkbHex(hex);
    expect(geometry).toEqual({ type: "MultiPolygon", coordinates: [[[[0, 0], [1, 0], [0, 1]]]] });
  });

  it("skips an EWKB srid and drops z ordinates", () => {
    // Point with SRID flag (0x20000000) and Z flag (0x80000000): 4326, (1, 2, 3).
    const hex = "01" + "010000a0" + "e6100000" + float(1) + float(2) + float(3);
    expect(decodeWkbHex(hex)).toEqual({ type: "Point", coordinates: [1, 2] });
  });

  it("rejects malformed input and unsupported types", () => {
    expect(() => decodeWkbHex("0x")).toThrow();
    expect(() => decodeWkbHex("01" + "07000000" + "00000000")).toThrow(/Unsupported/);
  });
});

function float(value: number): string {
  const buffer = new DataView(new ArrayBuffer(8));
  buffer.setFloat64(0, value, true);
  return Array.from(new Uint8Array(buffer.buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function floatBigEndian(value: number): string {
  const buffer = new DataView(new ArrayBuffer(8));
  buffer.setFloat64(0, value, false);
  return Array.from(new Uint8Array(buffer.buffer), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
