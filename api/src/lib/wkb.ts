/**
 * Decodes the Well-Known Binary geometries Overture stores in its GeoParquet
 * `geometry` column into GeoJSON. Points, line strings, polygons and their
 * multi variants are all Overture uses; anything else is reported as
 * unsupported rather than guessed at. Both byte orders and the EWKB SRID flag
 * are handled, and Z/M coordinates are dropped.
 *
 * Done here rather than with DuckDB's spatial extension so the fetch needs
 * only `httpfs` at runtime and the same decoder serves tests offline.
 */

export type WkbPosition = [longitude: number, latitude: number];

export type WkbGeometry =
  | { type: "Point"; coordinates: WkbPosition }
  | { type: "LineString"; coordinates: WkbPosition[] }
  | { type: "Polygon"; coordinates: WkbPosition[][] }
  | { type: "MultiPoint"; coordinates: WkbPosition[] }
  | { type: "MultiLineString"; coordinates: WkbPosition[][] }
  | { type: "MultiPolygon"; coordinates: WkbPosition[][][] };

const WKB_Z_FLAG = 0x80000000;
const WKB_M_FLAG = 0x40000000;
const WKB_SRID_FLAG = 0x20000000;

class WkbReader {
  private offset = 0;
  private littleEndian = true;

  constructor(private readonly view: DataView) {}

  readGeometry(): WkbGeometry {
    this.littleEndian = this.view.getUint8(this.offset) === 1;
    this.offset += 1;
    const rawType = this.view.getUint32(this.offset, this.littleEndian);
    this.offset += 4;
    if (rawType & WKB_SRID_FLAG) {
      this.offset += 4;
    }
    // ISO WKB encodes Z/M as +1000/+2000/+3000 on the type; EWKB as high
    // bits. Both are reduced to the base type, and the extra ordinates are
    // skipped when each position is read.
    const isoType = rawType & 0x0fffffff;
    const baseType = isoType % 1000;
    const dimensionCode = Math.floor(isoType / 1000);
    const hasZ = Boolean(rawType & WKB_Z_FLAG) || dimensionCode === 1 || dimensionCode === 3;
    const hasM = Boolean(rawType & WKB_M_FLAG) || dimensionCode >= 2;
    const extraOrdinates = (hasZ ? 1 : 0) + (hasM ? 1 : 0);

    switch (baseType) {
      case 1:
        return { type: "Point", coordinates: this.readPosition(extraOrdinates) };
      case 2:
        return { type: "LineString", coordinates: this.readPositions(extraOrdinates) };
      case 3:
        return { type: "Polygon", coordinates: this.readRings(extraOrdinates) };
      case 4:
        return { type: "MultiPoint", coordinates: this.readMany(() => this.readGeometry()).map(pointCoordinates) };
      case 5:
        return { type: "MultiLineString", coordinates: this.readMany(() => this.readGeometry()).map(lineCoordinates) };
      case 6:
        return { type: "MultiPolygon", coordinates: this.readMany(() => this.readGeometry()).map(polygonCoordinates) };
      default:
        throw new Error(`Unsupported WKB geometry type ${baseType}`);
    }
  }

  private readMany<Value>(readOne: () => Value): Value[] {
    const count = this.view.getUint32(this.offset, this.littleEndian);
    this.offset += 4;
    const values: Value[] = [];
    for (let index = 0; index < count; index += 1) {
      values.push(readOne());
    }
    return values;
  }

  private readRings(extraOrdinates: number): WkbPosition[][] {
    return this.readMany(() => this.readPositions(extraOrdinates));
  }

  private readPositions(extraOrdinates: number): WkbPosition[] {
    return this.readMany(() => this.readPosition(extraOrdinates));
  }

  private readPosition(extraOrdinates: number): WkbPosition {
    const longitude = this.view.getFloat64(this.offset, this.littleEndian);
    const latitude = this.view.getFloat64(this.offset + 8, this.littleEndian);
    this.offset += 16 + 8 * extraOrdinates;
    return [longitude, latitude];
  }
}

function pointCoordinates(geometry: WkbGeometry): WkbPosition {
  if (geometry.type !== "Point") {
    throw new Error(`Expected a Point inside a MultiPoint, got ${geometry.type}`);
  }
  return geometry.coordinates;
}

function lineCoordinates(geometry: WkbGeometry): WkbPosition[] {
  if (geometry.type !== "LineString") {
    throw new Error(`Expected a LineString inside a MultiLineString, got ${geometry.type}`);
  }
  return geometry.coordinates;
}

function polygonCoordinates(geometry: WkbGeometry): WkbPosition[][] {
  if (geometry.type !== "Polygon") {
    throw new Error(`Expected a Polygon inside a MultiPolygon, got ${geometry.type}`);
  }
  return geometry.coordinates;
}

export function decodeWkb(bytes: Uint8Array): WkbGeometry {
  return new WkbReader(new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)).readGeometry();
}

export function decodeWkbHex(hex: string): WkbGeometry {
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) {
    throw new Error("WKB hex string is malformed");
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return decodeWkb(bytes);
}
