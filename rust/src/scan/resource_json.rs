use anyhow::Result;
use serde_json::Value;

use super::{ExtractResourceParams, ScanItem};

#[derive(Debug)]
struct JsonLeaf {
    path: Vec<String>,
    lnum: u32,
    col: u32,
    end_col: u32,
}

struct JsonLeafScanner<'a> {
    source: &'a str,
    idx: usize,
    line: u32,
    col: u32,
    leaves: Vec<JsonLeaf>,
}

impl<'a> JsonLeafScanner<'a> {
    fn new(source: &'a str) -> Self {
        Self {
            source,
            idx: 0,
            line: 0,
            col: 0,
            leaves: Vec::new(),
        }
    }

    fn parse(mut self) -> Result<Vec<JsonLeaf>> {
        self.skip_ws();
        let mut path = Vec::new();
        self.parse_object(&mut path, false)?;
        self.skip_ws();
        if self.peek_char().is_some() {
            return Err(anyhow::anyhow!("unexpected trailing characters"));
        }
        Ok(self.leaves)
    }

    fn remaining(&self) -> &str {
        &self.source[self.idx..]
    }

    fn peek_char(&self) -> Option<char> {
        self.remaining().chars().next()
    }

    fn next_char(&mut self) -> Option<char> {
        let ch = self.peek_char()?;
        self.idx += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
            self.col = 0;
        } else {
            self.col += 1;
        }
        Some(ch)
    }

    fn consume_char(&mut self, target: char) -> bool {
        if self.peek_char() == Some(target) {
            let _ = self.next_char();
            true
        } else {
            false
        }
    }

    fn expect_char(&mut self, target: char) -> Result<()> {
        if self.consume_char(target) {
            Ok(())
        } else {
            Err(anyhow::anyhow!(
                "expected '{}' at line {}, col {}",
                target,
                self.line,
                self.col
            ))
        }
    }

    fn expect_literal(&mut self, literal: &str) -> Result<()> {
        for expected in literal.chars() {
            let actual = self.next_char();
            if actual != Some(expected) {
                return Err(anyhow::anyhow!(
                    "expected '{}' at line {}, col {}",
                    literal,
                    self.line,
                    self.col
                ));
            }
        }
        Ok(())
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek_char(), Some(' ' | '\n' | '\r' | '\t')) {
            let _ = self.next_char();
        }
    }

    fn parse_string(&mut self) -> Result<(String, u32, u32, u32)> {
        let start_line = self.line;
        let start_col = self.col;
        self.expect_char('"')?;
        let mut out = String::new();
        loop {
            let ch = self
                .next_char()
                .ok_or_else(|| anyhow::anyhow!("unterminated string"))?;
            if ch == '"' {
                return Ok((out, start_line, start_col, self.col));
            }
            if ch == '\\' {
                let escaped = self
                    .next_char()
                    .ok_or_else(|| anyhow::anyhow!("unterminated escape sequence"))?;
                match escaped {
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    'b' => out.push('\u{0008}'),
                    'f' => out.push('\u{000C}'),
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    'u' => {
                        let mut code: u32 = 0;
                        for _ in 0..4 {
                            let hex = self
                                .next_char()
                                .ok_or_else(|| anyhow::anyhow!("unterminated unicode escape"))?;
                            let value = hex.to_digit(16).ok_or_else(|| {
                                anyhow::anyhow!("invalid unicode escape at line {}", self.line)
                            })?;
                            code = (code << 4) | value;
                        }
                        if let Some(decoded) = char::from_u32(code) {
                            out.push(decoded);
                        }
                    }
                    _ => {
                        return Err(anyhow::anyhow!(
                            "invalid escape '{}' at line {}, col {}",
                            escaped,
                            self.line,
                            self.col
                        ));
                    }
                }
            } else {
                out.push(ch);
            }
        }
    }

    fn parse_number(&mut self) -> Result<()> {
        let _ = self.consume_char('-');
        match self.peek_char() {
            Some('0') => {
                let _ = self.next_char();
            }
            Some('1'..='9') => {
                let _ = self.next_char();
                while matches!(self.peek_char(), Some('0'..='9')) {
                    let _ = self.next_char();
                }
            }
            _ => {
                return Err(anyhow::anyhow!(
                    "invalid number at line {}, col {}",
                    self.line,
                    self.col
                ));
            }
        }

        if self.consume_char('.') {
            if !matches!(self.peek_char(), Some('0'..='9')) {
                return Err(anyhow::anyhow!(
                    "invalid fraction at line {}, col {}",
                    self.line,
                    self.col
                ));
            }
            while matches!(self.peek_char(), Some('0'..='9')) {
                let _ = self.next_char();
            }
        }

        if matches!(self.peek_char(), Some('e' | 'E')) {
            let _ = self.next_char();
            if matches!(self.peek_char(), Some('+' | '-')) {
                let _ = self.next_char();
            }
            if !matches!(self.peek_char(), Some('0'..='9')) {
                return Err(anyhow::anyhow!(
                    "invalid exponent at line {}, col {}",
                    self.line,
                    self.col
                ));
            }
            while matches!(self.peek_char(), Some('0'..='9')) {
                let _ = self.next_char();
            }
        }

        Ok(())
    }

    fn push_leaf(&mut self, path: &[String], lnum: u32, col: u32, end_col: u32) {
        self.leaves.push(JsonLeaf {
            path: path.to_vec(),
            lnum,
            col,
            end_col,
        });
    }

    fn parse_object(&mut self, path: &mut Vec<String>, skip_emit: bool) -> Result<()> {
        self.expect_char('{')?;
        self.skip_ws();
        if self.consume_char('}') {
            return Ok(());
        }

        loop {
            let (key, key_line, key_col, key_end_col) = self.parse_string()?;
            self.skip_ws();
            self.expect_char(':')?;
            self.skip_ws();

            path.push(key);
            self.parse_object_value(path, skip_emit, key_line, key_col, key_end_col)?;
            let _ = path.pop();

            self.skip_ws();
            if self.consume_char(',') {
                self.skip_ws();
                continue;
            }
            self.expect_char('}')?;
            break;
        }

        Ok(())
    }

    fn parse_object_value(
        &mut self,
        path: &mut Vec<String>,
        skip_emit: bool,
        key_line: u32,
        key_col: u32,
        key_end_col: u32,
    ) -> Result<()> {
        match self.peek_char() {
            Some('{') => self.parse_object(path, skip_emit),
            Some('[') => self.parse_array(path),
            Some('"') => {
                let _ = self.parse_string()?;
                if !skip_emit {
                    self.push_leaf(path, key_line, key_col, key_end_col);
                }
                Ok(())
            }
            Some('-' | '0'..='9') => {
                self.parse_number()?;
                if !skip_emit {
                    self.push_leaf(path, key_line, key_col, key_end_col);
                }
                Ok(())
            }
            Some('t') => {
                self.expect_literal("true")?;
                if !skip_emit {
                    self.push_leaf(path, key_line, key_col, key_end_col);
                }
                Ok(())
            }
            Some('f') => {
                self.expect_literal("false")?;
                if !skip_emit {
                    self.push_leaf(path, key_line, key_col, key_end_col);
                }
                Ok(())
            }
            Some('n') => {
                self.expect_literal("null")?;
                if !skip_emit {
                    self.push_leaf(path, key_line, key_col, key_end_col);
                }
                Ok(())
            }
            _ => Err(anyhow::anyhow!(
                "invalid value at line {}, col {}",
                self.line,
                self.col
            )),
        }
    }

    fn parse_array(&mut self, path: &mut Vec<String>) -> Result<()> {
        self.expect_char('[')?;
        self.skip_ws();
        if self.consume_char(']') {
            return Ok(());
        }
        loop {
            self.parse_array_value(path)?;
            self.skip_ws();
            if self.consume_char(',') {
                self.skip_ws();
                continue;
            }
            self.expect_char(']')?;
            break;
        }
        Ok(())
    }

    fn parse_array_value(&mut self, path: &mut Vec<String>) -> Result<()> {
        match self.peek_char() {
            Some('{') => self.parse_object(path, true),
            Some('[') => self.parse_array(path),
            Some('"') => {
                let _ = self.parse_string()?;
                Ok(())
            }
            Some('-' | '0'..='9') => self.parse_number(),
            Some('t') => self.expect_literal("true"),
            Some('f') => self.expect_literal("false"),
            Some('n') => self.expect_literal("null"),
            _ => Err(anyhow::anyhow!(
                "invalid array value at line {}, col {}",
                self.line,
                self.col
            )),
        }
    }
}

pub(super) fn extract_resource(params: ExtractResourceParams) -> Result<Value> {
    let leaves = JsonLeafScanner::new(&params.source).parse()?;
    let mut items = Vec::new();

    for leaf in leaves {
        let in_range = match &params.range {
            Some(range) => leaf.lnum >= range.start_line && leaf.lnum <= range.end_line,
            None => true,
        };
        if !in_range {
            continue;
        }

        if params.is_root {
            if leaf.path.len() < 2 {
                continue;
            }
            let namespace = leaf.path[0].clone();
            let raw = leaf.path[1..].join(".");
            if raw.is_empty() {
                continue;
            }
            items.push(ScanItem {
                key: format!("{}:{}", namespace, raw),
                raw,
                namespace,
                lnum: leaf.lnum,
                col: leaf.col,
                end_col: leaf.end_col,
                fallback: false,
            });
        } else {
            if leaf.path.is_empty() {
                continue;
            }
            let raw = leaf.path.join(".");
            items.push(ScanItem {
                key: format!("{}:{}", params.namespace, raw),
                raw,
                namespace: params.namespace.clone(),
                lnum: leaf.lnum,
                col: leaf.col,
                end_col: leaf.end_col,
                fallback: false,
            });
        }
    }

    Ok(serde_json::json!({ "items": items }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scan::Range;

    fn extract_items(
        source: &str,
        namespace: &str,
        is_root: bool,
        range: Option<Range>,
    ) -> Vec<ScanItem> {
        let result = extract_resource(ExtractResourceParams {
            source: source.to_string(),
            namespace: namespace.to_string(),
            is_root,
            range,
        })
        .expect("extract_resource should succeed");

        serde_json::from_value(result["items"].clone()).expect("items should deserialize")
    }

    #[test]
    fn extracts_root_resource_namespaces() {
        let items = extract_items(
            r#"{
  "common": { "login": { "title": "Login" } },
  "admin": { "save": "Save" }
}"#,
            "ignored",
            true,
            None,
        );

        assert_eq!(items.len(), 2);
        assert_eq!(items[0].key, "common:login.title");
        assert_eq!(items[1].key, "admin:save");
    }

    #[test]
    fn filters_resource_items_by_line_range() {
        let items = extract_items(
            r#"{
  "login": {
    "title": "Login",
    "desc": "Description"
  },
  "plain": "OK"
}"#,
            "common",
            false,
            Some(Range {
                start_line: 2,
                end_line: 2,
            }),
        );

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "common:login.title");
        assert_eq!(items[0].lnum, 2);
    }
}
