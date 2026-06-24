//! Dormant Rust-side shape for a possible future CEF bridge.
//!
//! This crate deliberately avoids Rustler and CEF dependencies for now. It
//! records the minimal native surface area DevIDE would need if the project
//! later chooses an in-BEAM native backend after proving crash behavior,
//! packaging, scheduler safety, and resource lifetime management.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeRef;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrowserRef;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeError {
    NotImplemented,
}

pub type BridgeResult<T> = Result<T, BridgeError>;

pub fn native_start_runtime(_config_json: &str) -> BridgeResult<RuntimeRef> {
    Err(BridgeError::NotImplemented)
}

pub fn native_create_browser(_runtime: RuntimeRef, _opts_json: &str) -> BridgeResult<BrowserRef> {
    Err(BridgeError::NotImplemented)
}

pub fn native_navigate(_browser: BrowserRef, _url: &str) -> BridgeResult<()> {
    Err(BridgeError::NotImplemented)
}

pub fn native_send_cdp(_browser: BrowserRef, _json: &str) -> BridgeResult<String> {
    Err(BridgeError::NotImplemented)
}

pub fn native_capture_screenshot(_browser: BrowserRef) -> BridgeResult<Vec<u8>> {
    Err(BridgeError::NotImplemented)
}

pub fn native_close_browser(_browser: BrowserRef) -> BridgeResult<()> {
    Err(BridgeError::NotImplemented)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_surface_is_explicitly_unimplemented() {
        assert_eq!(
            native_start_runtime("{}"),
            Err(BridgeError::NotImplemented)
        );
        assert_eq!(
            native_create_browser(RuntimeRef, "{}"),
            Err(BridgeError::NotImplemented)
        );
        assert_eq!(
            native_navigate(BrowserRef, "about:blank"),
            Err(BridgeError::NotImplemented)
        );
        assert_eq!(
            native_send_cdp(BrowserRef, "{}"),
            Err(BridgeError::NotImplemented)
        );
        assert_eq!(
            native_capture_screenshot(BrowserRef),
            Err(BridgeError::NotImplemented)
        );
        assert_eq!(
            native_close_browser(BrowserRef),
            Err(BridgeError::NotImplemented)
        );
    }
}
