// Shared diagram geometry: anchor points and edge routing for every renderer (SVG, PDF, PPTX).
"use strict";

const KIND = { // light palette (hex) used by PDF and PPTX; HTML uses CSS variables with the same names
  actor: { fill: "EEF0F3", stroke: "8A919C", text: "1B1E23" },
  edge:  { fill: "E8EEF7", stroke: "5B7BA8", text: "1B1E23" },
  boomi: { fill: "FFF3D6", stroke: "D99A00", text: "1B1E23" },
  data:  { fill: "DFF3EE", stroke: "1F8A70", text: "1B1E23" },
  ai:    { fill: "ECE6FA", stroke: "6B4FC7", text: "1B1E23" },
  ext:   { fill: "FDE7DE", stroke: "D0603A", text: "1B1E23" },
};

function center(n) { return { x: n.x + n.w / 2, y: n.y + n.h / 2 }; }

// Pick the facing sides of two boxes and return [start, end] points.
function anchors(a, b) {
  const ca = center(a), cb = center(b);
  const dx = cb.x - ca.x, dy = cb.y - ca.y;
  const overlapX = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
  const horizontal = overlapX < 20 && Math.abs(dx) > Math.abs(dy) * 0.6;
  if (horizontal) {
    const s = dx > 0 ? { x: a.x + a.w, y: ca.y } : { x: a.x, y: ca.y };
    const e = dx > 0 ? { x: b.x, y: cb.y } : { x: b.x + b.w, y: cb.y };
    return [s, e];
  }
  const s = dy > 0 ? { x: ca.x, y: a.y + a.h } : { x: ca.x, y: a.y };
  const e = dy > 0 ? { x: cb.x, y: b.y } : { x: cb.x, y: b.y + b.h };
  return [s, e];
}

// Return the polyline points for an edge.
// Horizontal neighbours: side to side (Z bend if offset). Vertical relation: leave the source's bottom/top at the
// x of the target centre (clamped into the source), enter the target at its top/bottom centre.
function route(d, edge) {
  const byId = Object.fromEntries(d.nodes.map((n) => [n.id, n]));
  const a = byId[edge.from], b = byId[edge.to];
  const ca = center(a), cb = center(b);
  const reverse = d.edges.some((o) => o !== edge && o.from === edge.to && o.to === edge.from);
  const off = reverse ? (edge.dashed ? 16 : -16) : 0;
  const below = b.y >= a.y + a.h - 1, above = b.y + b.h <= a.y + 1;
  if (!below && !above) { // same row: side to side
    const right = cb.x > ca.x;
    const s = { x: right ? a.x + a.w : a.x, y: ca.y + off }, e = { x: right ? b.x : b.x + b.w, y: cb.y + off };
    if (Math.abs(s.y - e.y) < 2) return [s, e];
    const mx = (s.x + e.x) / 2; return [s, { x: mx, y: s.y }, { x: mx, y: e.y }, e];
  }
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const sx = clamp(cb.x + off, a.x + 18, a.x + a.w - 18);
  const ex = Math.abs(sx - (cb.x + off)) < 2 ? sx : cb.x + off;
  const s = { x: sx, y: below ? a.y + a.h : a.y }, e = { x: ex, y: below ? b.y : b.y + b.h };
  if (Math.abs(s.x - e.x) < 2) return [s, { x: s.x, y: e.y }];
  const my = (s.y + e.y) / 2; return [s, { x: s.x, y: my }, { x: e.x, y: my }, e];
}

function labelPos(pts) { // midpoint of the longest segment
  let best = 0, bi = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const l = Math.hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y);
    if (l > best) { best = l; bi = i; }
  }
  return { x: (pts[bi].x + pts[bi + 1].x) / 2, y: (pts[bi].y + pts[bi + 1].y) / 2 };
}

module.exports = { KIND, route, labelPos, center };
