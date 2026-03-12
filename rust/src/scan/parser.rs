use anyhow::Result;
use swc_common::{FileName, SourceMap, Span, input::SourceFileInput, sync::Lrc};
use swc_ecma_ast::Module;
use swc_ecma_parser::{EsSyntax, Parser, Syntax, TsSyntax, lexer::Lexer};

pub(super) fn parse_module(source: &str, lang: &str) -> Result<(Module, Lrc<SourceMap>)> {
    let cm: Lrc<SourceMap> = Default::default();
    let fm = cm.new_source_file(
        Lrc::new(FileName::Custom("input".into())),
        source.to_string(),
    );

    let syntax = match lang {
        "tsx" => Syntax::Typescript(TsSyntax {
            tsx: true,
            ..Default::default()
        }),
        "typescript" => Syntax::Typescript(TsSyntax {
            tsx: false,
            ..Default::default()
        }),
        "jsx" => Syntax::Es(EsSyntax {
            jsx: true,
            ..Default::default()
        }),
        _ => Syntax::Es(EsSyntax {
            jsx: true,
            ..Default::default()
        }),
    };

    let lexer = Lexer::new(
        syntax,
        Default::default(),
        SourceFileInput::from(&*fm),
        None,
    );

    let mut parser = Parser::new_from(lexer);
    let module = parser
        .parse_module()
        .map_err(|e| anyhow::anyhow!("parse error: {:?}", e.into_kind().msg()))?;

    Ok((module, cm))
}

pub(super) fn span_to_loc(cm: &SourceMap, span: Span) -> (u32, u32, u32) {
    let lo = cm.lookup_char_pos(span.lo);
    let hi = cm.lookup_char_pos(span.hi);
    (
        lo.line as u32 - 1,
        lo.col_display as u32,
        hi.col_display as u32,
    )
}

pub(super) fn span_to_lines(cm: &SourceMap, span: Span) -> (u32, u32) {
    let (start, _, _) = span_to_loc(cm, span);
    let hi = cm.lookup_char_pos(span.hi);
    (start, hi.line as u32 - 1)
}
