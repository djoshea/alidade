//! alidade server library.
//!
//! The server owns all document state (the scene) and exposes a websocket
//! API to all clients. This library is intentionally kept thin of `main`
//! concerns so it remains unit-testable without a real socket — `main.rs`
//! is a tiny shell that calls into this library.
//!
//! Phase 0: no real logic yet.

/// Returns the lockstep version string baked in at build time.
///
/// Real `run()` semantics arrive in Phase 1 (the axum websocket server).
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_nonempty() {
        assert!(!version().is_empty());
    }
}
