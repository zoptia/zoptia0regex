//! zoptia0regex — a faithful Zig port of Go's `regexp` package (RE2 design).
//!
//! Pipeline: parse → simplify → compile → Pike VM, matching Go's leftmost-first
//! (and optional POSIX leftmost-longest) semantics. See README.md for the
//! supported feature set and the deliberately-deferred optimizations.

const regexp = @import("regexp.zig");

pub const Regexp = regexp.Regexp;
pub const Match = regexp.Match;
pub const ParseError = regexp.ParseError;
pub const ExecError = regexp.ExecError;

pub const compile = regexp.compile;
pub const compilePOSIX = regexp.compilePOSIX;
pub const mustCompile = regexp.mustCompile;
pub const quoteMeta = regexp.quoteMeta;

/// Low-level building blocks, exposed for advanced use and testing.
pub const syntax = struct {
    pub const ast = @import("ast.zig");
    pub const parse = @import("parse.zig");
    pub const simplify = @import("simplify.zig");
    pub const prog = @import("prog.zig");
    pub const compileProg = @import("compile.zig");
    pub const exec = @import("exec.zig");
    pub const onepass = @import("onepass.zig");
    pub const unicode = @import("unicode.zig");
};

test {
    _ = @import("unicode.zig");
    _ = @import("ast.zig");
    _ = @import("prog.zig");
    _ = @import("parse.zig");
    _ = @import("simplify.zig");
    _ = @import("compile.zig");
    _ = @import("exec.zig");
    _ = @import("regexp.zig");
    _ = @import("tests.zig");
}
