//! Bounded extraction clips. Only single convex quadrilaterals are recognized: these include
//! transformed form BBoxes. Unknown paths keep the previous constraint and a matching pop.
use kurbo::{BezPath, PathEl, Point};
use std::sync::Arc;

// Forms already have a nesting limit; explicit path clips need their own storage/work bounds.
// At this depth each convex intersection has at most 4 * (depth + 1) vertices, so the retained
// polygons use at most about 4 MiB. Work also bounds repeated intersections and glyph tests.
const MAX_DEPTH: usize = 256;
const MAX_WORK: usize = 1 << 22;
const MAX_VERTICES: usize = 4 * (MAX_DEPTH + 1);
pub(super) const LIMIT_ERROR: &str = "text clipping limit exceeded";

pub(super) struct TextClips {
    stack: Vec<Option<Arc<[Point]>>>,
    remaining: usize,
    pub(super) exceeded: bool,
}

impl Default for TextClips {
    fn default() -> Self {
        Self { stack: Vec::new(), remaining: MAX_WORK, exceeded: false }
    }
}

impl TextClips {
    fn spend(&mut self, amount: usize) -> bool {
        if self.exceeded {
            return false;
        }
        match self.remaining.checked_sub(amount) {
            Some(left) => {
                self.remaining = left;
                true
            }
            None => {
                self.exceeded = true;
                false
            }
        }
    }

    pub(super) fn push(&mut self, path: &BezPath) {
        if self.stack.len() >= MAX_DEPTH {
            self.exceeded = true;
        }
        if !self.spend(7) {
            return;
        }
        let previous = self.stack.last().cloned().flatten();
        let Some(quad) = quadrilateral(path) else {
            self.stack.push(previous);
            return;
        };
        let region = match previous.as_deref() {
            None => Some(quad),
            Some(old) if old.is_empty() || quad.is_empty() => Some(Vec::new()),
            Some(old) => {
                // Four half-plane passes; charge before allocating or scanning their vertices.
                if !self.spend(old.len().saturating_add(4).saturating_mul(16)) {
                    return;
                }
                match intersect(old, &quad) {
                    Ok(region) => region,
                    Err(()) => {
                        self.exceeded = true;
                        return;
                    }
                }
            }
        };
        // Nonfinite arithmetic is uncertain, not evidence of an empty intersection.
        self.stack.push(region.map(|p| Arc::from(p.into_boxed_slice())).or(previous));
    }

    pub(super) fn pop(&mut self) {
        self.stack.pop();
    }

    pub(super) fn visible(&mut self, quad: &[Point; 4]) -> bool {
        if self.exceeded {
            return false;
        }
        let Some(Some(region)) = self.stack.last().cloned() else {
            return true;
        };
        if region.is_empty() {
            return false;
        }
        if !self.spend(region.len().saturating_add(4).saturating_mul(8)) {
            return false;
        }
        // Separating axes of both convex polygons distinguish the real transformed geometry
        // from its enclosing rectangle. Strict separation retains boundary contact and lines.
        if edges(&region).any(|(a, b)| outside(a, b, quad, 1.0)) {
            return false;
        }
        let area = area(quad);
        if area.is_finite() && area != 0.0 {
            let sign = area.signum();
            if edges(quad).any(|(a, b)| outside(a, b, &region, sign)) {
                return false;
            }
        }
        true
    }
}

fn edges(points: &[Point]) -> impl Iterator<Item = (Point, Point)> + '_ {
    points.iter().copied().zip(points.iter().copied().cycle().skip(1)).take(points.len())
}

fn cross(a: Point, b: Point, p: Point) -> f64 {
    (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
}

fn tolerance(a: Point, b: Point, p: Point) -> f64 {
    32.0 * f64::EPSILON * (((b.x - a.x) * (p.y - a.y)).abs() + ((b.y - a.y) * (p.x - a.x)).abs()).max(1.0)
}

fn outside(a: Point, b: Point, points: &[Point], sign: f64) -> bool {
    points.iter().all(|&p| {
        let side = sign * cross(a, b, p);
        side.is_finite() && side < -tolerance(a, b, p)
    })
}

fn area(points: &[Point]) -> f64 {
    let Some(&origin) = points.first() else {
        return 0.0;
    };
    edges(points).map(|(a, b)| cross(origin, a, b)).sum()
}

fn quadrilateral(path: &BezPath) -> Option<Vec<Point>> {
    use PathEl::{ClosePath, LineTo, MoveTo};
    let [a, b, c, d] = match path.elements() {
        [MoveTo(a), LineTo(b), LineTo(c), LineTo(d), ClosePath] => [*a, *b, *c, *d],
        [MoveTo(a), LineTo(b), LineTo(c), LineTo(d), LineTo(end), ClosePath] if a == end => [*a, *b, *c, *d],
        _ => return None,
    };
    let points = [a, b, c, d];
    if !points.iter().all(|p| p.x.is_finite() && p.y.is_finite()) {
        return None;
    }
    let turns = [cross(a, b, c), cross(b, c, d), cross(c, d, a), cross(d, a, b)];
    if !turns.iter().all(|v| v.is_finite()) {
        return None;
    }
    if !(turns.iter().all(|&v| v >= 0.0) || turns.iter().all(|&v| v <= 0.0)) {
        return None;
    }
    if turns.iter().all(|&v| v == 0.0) {
        // A collapsed form rectangle repeats its endpoints. Other apparent collinearity can
        // be floating-point underflow; do not mistake that uncertainty for an empty clip.
        let collapsed = (a == b && c == d) || (a == d && b == c) || points.iter().all(|p| p.x == a.x) || points.iter().all(|p| p.y == a.y);
        return collapsed.then(Vec::new);
    }
    let signed = area(&points);
    if !signed.is_finite() || signed == 0.0 {
        return None;
    }
    let mut result = points.to_vec();
    if signed < 0.0 {
        result.reverse();
    }
    Some(result)
}

fn intersect(subject: &[Point], clip: &[Point]) -> Result<Option<Vec<Point>>, ()> {
    let mut result = subject.to_vec();
    for (a, b) in edges(clip) {
        let mut next = Vec::with_capacity(result.len().saturating_add(1));
        for (start, end) in edges(&result) {
            let s = cross(a, b, start);
            let e = cross(a, b, end);
            if !s.is_finite() || !e.is_finite() {
                return Ok(None);
            }
            let inside_start = s >= -tolerance(a, b, start);
            let inside_end = e >= -tolerance(a, b, end);
            if inside_start != inside_end {
                let fraction = s / (s - e);
                if !fraction.is_finite() {
                    return Ok(None);
                }
                let p = start + (end - start) * fraction.clamp(0.0, 1.0);
                if !p.x.is_finite() || !p.y.is_finite() {
                    return Ok(None);
                }
                next.push(p);
            }
            if inside_end {
                next.push(end);
            }
        }
        next.dedup();
        if next.len() > 1 && next.first() == next.last() {
            next.pop();
        }
        // Roundoff must not invalidate the storage bound even if it creates extra vertices.
        if next.len() > MAX_VERTICES {
            return Err(());
        }
        result = next;
    }
    let signed = area(&result);
    if !signed.is_finite() {
        return Ok(None);
    }
    if result.len() < 3 {
        result.clear();
    } else if signed == 0.0 {
        return Ok(None);
    }
    Ok(Some(result))
}
