mod doctor;
mod hardcoded;
mod resolve;
mod resource;
mod rpc;
mod scan;
mod util;

use anyhow::Result;
use resource::index::IndexCache;
use rpc::{
    INTERNAL_ERROR, INVALID_PARAMS, INVALID_REQUEST, METHOD_NOT_FOUND, Notification, Response,
    Transport,
};
use serde_json::{Value, json};
use std::process;

struct Server {
    transport: Transport,
    index_cache: IndexCache,
    initialized: bool,
}

impl Server {
    fn new() -> Self {
        Self {
            transport: Transport::new(),
            index_cache: IndexCache::new(),
            initialized: false,
        }
    }

    fn run(&mut self) -> Result<()> {
        eprintln!("i18n-status-core: server starting");

        loop {
            let request = match self.transport.read_message() {
                Ok(Some(req)) => req,
                Ok(None) => {
                    eprintln!("i18n-status-core: EOF, shutting down");
                    break;
                }
                Err(e) => {
                    eprintln!("i18n-status-core: read error: {}", e);
                    continue;
                }
            };

            if request.jsonrpc != "2.0" {
                if request.id.is_some() {
                    let response = Response::error(
                        request.id.clone(),
                        INVALID_REQUEST,
                        "invalid jsonrpc version".to_string(),
                    );
                    let _ = self.transport.send_response(&response);
                }
                continue;
            }

            // Notifications have no id
            if request.id.is_none() {
                continue;
            }

            let id = request.id.clone();
            let response = self.dispatch(&request.method, request.params, id.clone());
            if let Err(e) = self.transport.send_response(&response) {
                eprintln!("i18n-status-core: send error: {}", e);
            }
        }

        Ok(())
    }

    fn dispatch(&mut self, method: &str, params: Value, id: Option<Value>) -> Response {
        match method {
            "initialize" => {
                self.initialized = true;
                Response::success(
                    id,
                    json!({
                        "name": "i18n-status-core",
                        "version": env!("CARGO_PKG_VERSION")
                    }),
                )
            }

            "shutdown" => {
                eprintln!("i18n-status-core: shutdown requested");
                let resp = Response::success(id, json!(null));
                // Send response then exit
                let _ = self.transport.send_response(&resp);
                process::exit(0);
            }

            "scan/extract" => match serde_json::from_value(params) {
                Ok(p) => match scan::extract(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "scan/extractResource" => match serde_json::from_value(params) {
                Ok(p) => match scan::extract_resource(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "scan/translationContextAt" => match serde_json::from_value(params) {
                Ok(p) => match scan::translation_context_at(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resolve/compute" => match serde_json::from_value(params) {
                Ok(p) => match resolve::compute(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resource/buildIndex" => match serde_json::from_value(params) {
                Ok(p) => match resource::index::build_index(p, &self.index_cache) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resource/resolveRoots" => match serde_json::from_value(params) {
                Ok(p) => match resource::discovery::resolve_roots(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "resource/applyChanges" => match serde_json::from_value(params) {
                Ok(p) => match resource::index::apply_changes(p, &self.index_cache) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "doctor/diagnose" => match serde_json::from_value(params) {
                Ok(p) => {
                    let transport = &self.transport;
                    let notify = |method: &str, params: Value| {
                        let notification = Notification::new(method, params);
                        let _ = transport.send_notification(&notification);
                    };
                    match doctor::diagnose(p, &notify) {
                        Ok(result) => Response::success(id, result),
                        Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                    }
                }
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            "hardcoded/extract" => match serde_json::from_value(params) {
                Ok(p) => match hardcoded::extract(p) {
                    Ok(result) => Response::success(id, result),
                    Err(e) => Response::error(id, INTERNAL_ERROR, e.to_string()),
                },
                Err(e) => Response::error(id, INVALID_PARAMS, e.to_string()),
            },

            _ => Response::error(
                id,
                METHOD_NOT_FOUND,
                format!("method not found: {}", method),
            ),
        }
    }
}

fn main() {
    let mut server = Server::new();
    if let Err(e) = server.run() {
        eprintln!("i18n-status-core: fatal error: {}", e);
        process::exit(1);
    }
}
