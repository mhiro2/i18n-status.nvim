use serde::{Deserialize, Serialize};

/// Identity of the Lua client this core speaks to.
pub const CLIENT_NAME: &str = "i18n-status.nvim";
/// Identity of this core, pinned by `core-contract.json`.
pub const CORE_NAME: &str = env!("CARGO_PKG_NAME");
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
/// Bumped whenever a wire change makes an older client incompatible.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Deserialize)]
pub struct Identity {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Deserialize)]
pub struct InitializeParams {
    pub client: Identity,
    pub protocol_version: u32,
}

#[derive(Debug, Serialize)]
pub struct InitializeResult {
    pub core: CoreIdentity,
    pub protocol_version: u32,
}

#[derive(Debug, Serialize)]
pub struct CoreIdentity {
    pub name: &'static str,
    pub version: &'static str,
}

impl InitializeResult {
    pub fn current() -> Self {
        Self {
            core: CoreIdentity {
                name: CORE_NAME,
                version: CORE_VERSION,
            },
            protocol_version: PROTOCOL_VERSION,
        }
    }
}

pub fn validate_client(params: &InitializeParams) -> Result<(), String> {
    if params.client.name != CLIENT_NAME {
        return Err(format!(
            "client name mismatch: expected {CLIENT_NAME}, got {}",
            params.client.name
        ));
    }
    if params.client.version != CORE_VERSION {
        return Err(format!(
            "client version mismatch: expected {CORE_VERSION}, got {}",
            params.client.version
        ));
    }
    if params.protocol_version != PROTOCOL_VERSION {
        return Err(format!(
            "protocol version mismatch: expected {PROTOCOL_VERSION}, got {}",
            params.protocol_version
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_params() -> InitializeParams {
        InitializeParams {
            client: Identity {
                name: CLIENT_NAME.to_string(),
                version: CORE_VERSION.to_string(),
            },
            protocol_version: PROTOCOL_VERSION,
        }
    }

    #[test]
    fn accepts_the_current_client_contract() {
        assert!(validate_client(&valid_params()).is_ok());
    }

    #[test]
    fn rejects_a_different_client_name() {
        let mut params = valid_params();
        params.client.name = "other.nvim".to_string();
        assert_eq!(
            validate_client(&params).unwrap_err(),
            format!("client name mismatch: expected {CLIENT_NAME}, got other.nvim")
        );
    }

    #[test]
    fn rejects_a_different_client_version() {
        let mut params = valid_params();
        params.client.version = "9.9.9".to_string();
        assert_eq!(
            validate_client(&params).unwrap_err(),
            format!("client version mismatch: expected {CORE_VERSION}, got 9.9.9")
        );
    }

    #[test]
    fn rejects_a_different_protocol_version() {
        let mut params = valid_params();
        params.protocol_version += 1;
        assert_eq!(
            validate_client(&params).unwrap_err(),
            format!(
                "protocol version mismatch: expected {PROTOCOL_VERSION}, got {}",
                PROTOCOL_VERSION + 1
            )
        );
    }
}
