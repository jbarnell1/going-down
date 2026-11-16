// Accumulates quads into one BufferGeometry, so a whole floor is a few draw calls, not thousands.

import * as THREE from 'three';

export type V3 = readonly [number, number, number];
export type RGB = readonly [number, number, number];

export class GeoBuilder {
  private pos: number[] = [];
  private nrm: number[] = [];
  private uv: number[] = [];
  private col: number[] = [];
  private idx: number[] = [];

  get empty(): boolean {
    return this.idx.length === 0;
  }

  /**
   * A parallelogram with corners o, o+u, o+u+v, o+v. Its front faces along cross(u, v).
   * `uvs` are [u0, v0, u1, v1] for the o and o+u+v corners. `colours` are per corner in the same
   * order as the corners, or one colour for all four.
   */
  quad(o: V3, u: V3, v: V3, colours: RGB | readonly [RGB, RGB, RGB, RGB], uvs: readonly [number, number, number, number] = [0, 0, 1, 1]): void {
    const nx = u[1] * v[2] - u[2] * v[1];
    const ny = u[2] * v[0] - u[0] * v[2];
    const nz = u[0] * v[1] - u[1] * v[0];
    const nl = Math.hypot(nx, ny, nz) || 1;
    const base = this.pos.length / 3;
    const corners: V3[] = [o, [o[0] + u[0], o[1] + u[1], o[2] + u[2]], [o[0] + u[0] + v[0], o[1] + u[1] + v[1], o[2] + u[2] + v[2]], [o[0] + v[0], o[1] + v[1], o[2] + v[2]]];
    const [u0, v0, u1, v1] = uvs;
    const cuv: [number, number][] = [[u0, v0], [u1, v0], [u1, v1], [u0, v1]];
    const perCorner = Array.isArray(colours[0]);
    for (let i = 0; i < 4; i++) {
      const c = corners[i] as V3;
      this.pos.push(c[0], c[1], c[2]);
      this.nrm.push(nx / nl, ny / nl, nz / nl);
      const t = cuv[i] as [number, number];
      this.uv.push(t[0], t[1]);
      const k = (perCorner ? (colours as readonly RGB[])[i] : (colours as RGB)) as RGB;
      this.col.push(k[0], k[1], k[2]);
    }
    this.idx.push(base, base + 1, base + 2, base, base + 2, base + 3);
  }

  /** Like quad, but flips the winding if needed so the front faces along `facing`. */
  quadFacing(o: V3, u: V3, v: V3, facing: V3, colours: RGB, uvs: readonly [number, number, number, number] = [0, 0, 1, 1]): void {
    const nx = u[1] * v[2] - u[2] * v[1];
    const ny = u[2] * v[0] - u[0] * v[2];
    const nz = u[0] * v[1] - u[1] * v[0];
    if (nx * facing[0] + ny * facing[1] + nz * facing[2] >= 0) {
      this.quad(o, u, v, colours, uvs);
    } else {
      this.quad([o[0] + u[0], o[1] + u[1], o[2] + u[2]], [-u[0], -u[1], -u[2]], v, colours, [uvs[2], uvs[1], uvs[0], uvs[3]]);
    }
  }

  /** An axis-aligned box, all six faces. */
  box(min: V3, max: V3, colour: RGB): void {
    const [x0, y0, z0] = min;
    const [x1, y1, z1] = max;
    const dx = x1 - x0;
    const dy = y1 - y0;
    const dz = z1 - z0;
    this.quad([x1, y0, z1], [0, 0, -dz], [0, dy, 0], colour);
    this.quad([x0, y0, z0], [0, 0, dz], [0, dy, 0], colour);
    this.quad([x0, y0, z1], [dx, 0, 0], [0, dy, 0], colour);
    this.quad([x1, y0, z0], [-dx, 0, 0], [0, dy, 0], colour);
    this.quad([x0, y1, z1], [dx, 0, 0], [0, 0, -dz], colour);
    this.quad([x0, y0, z0], [dx, 0, 0], [0, 0, dz], colour);
  }

  build(): THREE.BufferGeometry {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(this.pos, 3));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(this.nrm, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(this.uv, 2));
    g.setAttribute('color', new THREE.Float32BufferAttribute(this.col, 3));
    g.setIndex(this.idx);
    g.computeBoundingSphere();
    return g;
  }
}
