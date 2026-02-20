use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{self, BufRead, BufReader, Write};
use std::thread;
use std::time::Duration;

#[derive(Debug, Deserialize)]
pub struct Request {
    pub jsonrpc: String,
    pub id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct Notification {
    pub jsonrpc: String,
    pub method: String,
    pub params: Value,
}

// Standard JSON-RPC error codes
#[allow(dead_code)]
pub const PARSE_ERROR: i32 = -32700;
pub const INVALID_REQUEST: i32 = -32600;
pub const METHOD_NOT_FOUND: i32 = -32601;
pub const INVALID_PARAMS: i32 = -32602;
pub const INTERNAL_ERROR: i32 = -32603;

impl Response {
    pub fn success(id: Option<Value>, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Option<Value>, code: i32, message: String) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(RpcError {
                code,
                message,
                data: None,
            }),
        }
    }
}

impl Notification {
    pub fn new(method: &str, params: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            method: method.to_string(),
            params,
        }
    }
}

/// Reads JSON-RPC messages from stdin using newline-delimited JSON.
pub struct Transport {
    reader: BufReader<io::Stdin>,
}

fn parse_message_line(line: &str) -> Result<Option<Request>> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let request: Request =
        serde_json::from_str(trimmed).context("failed to parse JSON-RPC request")?;
    Ok(Some(request))
}

fn read_message_from_reader<R: BufRead>(reader: &mut R) -> Result<Option<Request>> {
    loop {
        let mut line = String::new();
        let bytes_read = match reader.read_line(&mut line) {
            Ok(bytes_read) => bytes_read,
            Err(err) => match err.kind() {
                io::ErrorKind::Interrupted => continue,
                io::ErrorKind::BrokenPipe => return Ok(None),
                io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(1));
                    continue;
                }
                _ => return Err(err).context("failed to read from stdin"),
            },
        };

        if bytes_read == 0 {
            return Ok(None); // EOF
        }

        if let Some(request) = parse_message_line(&line)? {
            return Ok(Some(request));
        }
    }
}

impl Transport {
    pub fn new() -> Self {
        Self {
            reader: BufReader::new(io::stdin()),
        }
    }

    pub fn read_message(&mut self) -> Result<Option<Request>> {
        read_message_from_reader(&mut self.reader)
    }

    pub fn send_response(&self, response: &Response) -> Result<()> {
        let json = serde_json::to_string(response)?;
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        writeln!(handle, "{}", json)?;
        handle.flush()?;
        Ok(())
    }

    pub fn send_notification(&self, notification: &Notification) -> Result<()> {
        let json = serde_json::to_string(notification)?;
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        writeln!(handle, "{}", json)?;
        handle.flush()?;
        Ok(())
    }
}

impl Default for Transport {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::read_message_from_reader;
    use std::io::{self, BufRead, BufReader, Cursor, Read};

    struct BrokenPipeReader;

    impl Read for BrokenPipeReader {
        fn read(&mut self, _buf: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "broken pipe"))
        }
    }

    impl BufRead for BrokenPipeReader {
        fn fill_buf(&mut self) -> io::Result<&[u8]> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "broken pipe"))
        }

        fn consume(&mut self, _amt: usize) {}

        fn read_line(&mut self, _buf: &mut String) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "broken pipe"))
        }
    }

    struct InterruptedThenMessageReader {
        interrupted_once: bool,
        cursor: Cursor<Vec<u8>>,
    }

    impl InterruptedThenMessageReader {
        fn new(input: &str) -> Self {
            Self {
                interrupted_once: false,
                cursor: Cursor::new(input.as_bytes().to_vec()),
            }
        }
    }

    impl Read for InterruptedThenMessageReader {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.cursor.read(buf)
        }
    }

    impl BufRead for InterruptedThenMessageReader {
        fn fill_buf(&mut self) -> io::Result<&[u8]> {
            self.cursor.fill_buf()
        }

        fn consume(&mut self, amt: usize) {
            self.cursor.consume(amt)
        }

        fn read_line(&mut self, buf: &mut String) -> io::Result<usize> {
            if !self.interrupted_once {
                self.interrupted_once = true;
                return Err(io::Error::new(io::ErrorKind::Interrupted, "interrupted"));
            }
            self.cursor.read_line(buf)
        }
    }

    #[test]
    fn read_message_skips_blank_lines() {
        let input =
            "\n  \n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n";
        let mut reader = BufReader::new(Cursor::new(input.as_bytes()));

        let request = read_message_from_reader(&mut reader)
            .expect("read_message should succeed")
            .expect("request should exist");
        assert_eq!(request.jsonrpc, "2.0");
        assert_eq!(request.method, "initialize");
    }

    #[test]
    fn read_message_returns_eof_after_messages() {
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n";
        let mut reader = BufReader::new(Cursor::new(input.as_bytes()));

        let first = read_message_from_reader(&mut reader).expect("first read should succeed");
        assert!(first.is_some());

        let second = read_message_from_reader(&mut reader).expect("second read should succeed");
        assert!(second.is_none());
    }

    #[test]
    fn read_message_treats_broken_pipe_as_eof() {
        let mut reader = BrokenPipeReader;
        let request =
            read_message_from_reader(&mut reader).expect("broken pipe should be treated as eof");
        assert!(request.is_none());
    }

    #[test]
    fn read_message_retries_after_interrupted() {
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n";
        let mut reader = InterruptedThenMessageReader::new(input);
        let request = read_message_from_reader(&mut reader)
            .expect("read_message should recover from interrupted")
            .expect("request should be parsed");
        assert_eq!(request.method, "initialize");
    }
}
