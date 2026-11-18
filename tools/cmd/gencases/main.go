// Command gencases generates test/data/cases.jsonl, the curated
// differential corpus: hand-picked patterns run on hand-picked inputs, Go's
// own invalid / Perl-only / POSIX-only parser test lists in both syntaxes,
// and the parser resource-limit boundaries. Run via tools/regen.sh.
package main

import (
	"strings"

	"zoptia0regex/tools/internal/corpus"
)

// patterns are the curated Perl-syntax patterns, each run on every input.
var patterns = []string{
	// literals & basics
	"", "abc", "a", "a.c", "a.*c", "a.*?c", "a.+c", "a.+?c",
	"^abc$", "^a", "c$", "\\Aabc\\z", "a|b|c", "abc|abd",
	// classes
	"[abc]", "[a-z]", "[^a-z]", "[a-z]+", "[^a-z]+", "[0-9]{2,4}",
	"[a-zA-Z0-9_]+", "[[:alpha:]]+", "[[:^alpha:]]+", "[\\d]+", "[\\D]+",
	"\\d+", "\\D+", "\\w+", "\\W+", "\\s+", "\\S+", "[-a]", "[a-]", "[]a]",
	"[^]a]", "[a\\-z]", "[\\x41-\\x5a]+",
	// quantifiers
	"a*", "a+", "a?", "a{3}", "a{2,}", "a{2,4}", "a{0,2}", "(ab)*", "(ab)+",
	"a*?", "a+?", "a??", "(a|b)*", "(a|b)+c", "colou?r",
	// groups & captures
	"(a)(b)(c)", "(a(b)c)", "(?:abc)+", "(?P<x>\\d+)-(?P<y>\\d+)",
	"(foo|bar)baz", "((a)|(b))+", "(a)|(b)|(c)",
	// anchors & boundaries
	"\\bword\\b", "\\Bin\\B", "^.", ".$", "(?m)^a", "(?m)a$",
	// flags
	"(?i)abc", "(?i)[a-z]+", "(?s)a.b", "(?i)straße", "(?i)Σ", "(?i)K",
	"a(?i)bc", "(?i:ab)c",
	// escapes
	"a\\.b", "a\\*b", "\\$", "\\^", "\\(", "\\n", "\\t", "\\x{1F600}",
	"\\101", "\\0", "\\\\",
	// unicode classes: Go's full category/script set, aliases, canonical
	// names (Go 1.27 script lookup), special cases, and the (?i) fold merge
	"\\pL+", "\\p{Greek}+", "\\p{Latin}+", "\\PL+", "\\p{Nd}+",
	"[\\p{L}\\d]+", "\\p{Han}+", "\\pN+", "\\p{Lu}+", "\\p{Ll}+", "\\p{Lt}+",
	"\\p{Zs}+", "\\p{Sm}+", "\\p{So}+", "\\p{Cn}+", "\\p{LC}+", "\\p{Lc}+", "\\p{lc}+",
	"\\p{Any}+", "\\p{Assigned}+", "\\P{Assigned}+", "\\p{ASCII}+", "\\P{ASCII}+", "\\p{ascii}+",
	"(?i)\\p{Lu}+", "(?i)\\p{Ll}+", "(?i)\\P{Lu}+", "(?i)\\P{Ll}+", "(?i)\\p{Lt}+", "(?i)\\p{L}+",
	"(?i)\\p{M}+", "(?i)\\p{Mn}+", "(?i)\\p{Greek}+", "(?i)\\p{Common}+", "(?i)\\p{Inherited}+",
	"(?i)\\p{ASCII}+", "(?i)\\P{ASCII}+", "(?i)[\\p{Lu}]+", "(?i)[^\\p{Lu}]+", "(?i)[\\p{Lu}\\d]+",
	"(?i)\\p{Nd}+", "(?i)\\p{Any}+", "(?i)\\p{Assigned}+",
	"\\p{Letter}+", "\\p{Uppercase_Letter}+", "\\p{upper case-let ter}+", "\\p{__upper case-let ter}+",
	"\\p{Decimal_Number}+", "\\p{digit}+", "\\p{punct}+", "\\p{cntrl}+", "\\p{Unassigned}+",
	"\\p{Cased_Letter}+", "(?i)\\p{Lowercase_Letter}+", "\\P{Letter}+",
	"\\p{Old_Italic}+", "\\p{old italic}+", "\\p{OldItalic}+", "\\p{Canadian_Aboriginal}+",
	"\\p{canadianaboriginal}+", "\\p{Garay}+", "\\p{latin}+", "\\p{LATIN}+", "\\p{greek}+",
	"\\p{Inherited}+", "\\p{Common}+", "\\p{Sidetic}+", "\\p{Tai_Yo}+",
	"\\p{^Greek}+", "\\P{^Greek}+", "[^\\p{L}]+", "[\\p{Lu}\\p{Nd}]+", "[\\P{L}\\P{N}]+",
	"\\p{Nonexistent}", "\\p{Letters}", "\\p{}", "\\p", "\\pX", "\\p{L", "\\p{^}",
	// real-world-ish
	"https?://[\\w.]+", "\\w+@\\w+\\.\\w+", "\\d{4}-\\d{2}-\\d{2}",
	"#[0-9a-fA-F]{6}", "(\\d+)\\.(\\d+)", "[A-Za-z]+\\s+\\d+",
	// empty & nullable subtleties
	"a*b*", "(a*)*", "(a*)+", "(|a)", "(a|)", "()", "(?:)*", "x*y*z*",
	"(a+)+", "(a?)*", ".*", ".+", "^$", "(^|a)b",
	// alternation priority
	"a|ab", "ab|a", "(a|ab)(c|bcd)", "foo|foobar",
	// nested
	"((a|b)c)+d", "(a(b(c)))", "(?:(?:ab)+)+",
	// compiled-away capture groups (padding edge cases)
	"(a){0}", "(a){0}b", "(x){0}|y", "(a)(b){0}(c)", "(\\w){0}x", "(ab){0,0}c",
	// alternation factoring (Go's factor): common literal prefixes,
	// common leading classes / fixed repeats, runs of single runes
	// merged into classes, empty alternatives, and the shapes factor
	// must NOT merge (quantified prefixes, differing flags)
	"abc|abd", "ABC|ABD|AEF|BCX|BCY", "foo|foobar|fo", "fo|foo|foobar",
	"a|b|c|d", "[ab]|c|[d-f]", ".|\\n", "a||b", "|a", "a|", "a|b|", "(?:)|a|(?:)",
	"(a)|(ab)", "(ab)|(ac)", "(?i)ab|AC", "(?i:ab)|ac", "ab|(?i:ac)", "x*|x*y",
	"[ab]{2}c|[ab]{2}d", "[ab]{1,2}c|[ab]{1,2}d", "\\d\\d|\\d\\w", "a*?b|a*?c",
	"(?U)a+b|a+c", "[a]b|[a]c", "[Aa]x|[Aa]y", "colou?r|colour", "(?s).a|.b",
	"the|then|there|these|they|this|that|than|thaw",
	"quick|quiet|quit|quite|quiz|brown|brow|bro|fox|foxy|fo",
	"(?i)hello|help|helm|HELIX|world|word|work", "ab(c|d)|ab(c|e)",
	"a(b|c)d|a(b|c)e", "(?:ab|ac)+", "(?:ab|ac)*d", "(ab|ac){2}", "\\bthe|\\bthen",
	"^ab|^ac", "ab$|ac$", "a\\b|a\\B", "日本|日本語|日", "αβ|αγ|Αδ", "(?i)σ|ς|Σx",
	"\\pL|\\pN|x", "[^a]|b|c", "[a-c]|[b-d]", "a|[^a]", "\\x{10FFFF}|\\x{10FFFE}",
	// dot variants
	".", "..", "...",
	// repetition of classes
	"[ab]{2,3}", "[^x]{3}",
}

// inputs are the curated inputs.
var inputs = []string{
	"", "a", "ab", "abc", "abd", "aXc", "a\nc", "aaa", "aaaa", "aaaaa",
	"xyz", "abcabc", "ababab", "Hello World 123", "foo bar baz",
	"colour color colouur", "the quick brown fox", "word boundary in text",
	"ΑΒΓ αβγ δεζ", "héllo wörld", "日本語 test 123", "straße STRASSE",
	"Σ σ ς", "Kelvin K K", "2024-01-15 and 2025-12-31",
	"#FF00aa color", "3.14 and 2.71", "me@example.com you@test.org",
	"https://example.com/path http://x.io", "  spaces  tabs\t\tend",
	"123abc456def", "AaBbCc", "ABCDEF", "abcdef", "x", "xx", "xxx",
	"a-b-c", "[a]", "]", "-", "\U0001F600 emoji", "abcXYZ123",
	"aaAAaa", "STRASSE", "ﬀ ﬁ",
	"then there these they thaw", "quiet quiz foxy bro", "HELLO helm Helix work",
	"abcabdabe", "ac ab ad abab", "日本語 日 αγ Αδ ς",
	// Unicode 16/17 additions and fold-table edge cases
	"\U00010D50\U00010D70 garay", "\U0001CC00 legacy symbol", "\U00010300 old italic",
	"\u1401\u1403 canadian", "\u01C5\u01C8 titlecase", "\u0345 ypogegrammeni \u03B9",
	"\u00AA\u00BA ordinal", "\U000E0001 tag", "\uFDD0\uFFFF noncharacter", "\u2167 \u2177 roman",
	"\u017F long s", "\u212A kelvin", "\U00010940 sidetic", "\U0001E5D0 ol onal",
}

// Copied from Go 1.27.1 src/regexp/syntax/parse_test.go (invalidRegexps),
// minus strings.Repeat(`\pL`, 27000), which exceeds corpus.MaxPatternLen
// (the rune budget is covered by src/limitstest.zig).
var invalidRegexps = []string{
	`(`,
	`)`,
	`(a`,
	`a)`,
	`(a))`,
	`(a|b|`,
	`a|b|)`,
	`(a|b|))`,
	`(a|b`,
	`a|b)`,
	`(a|b))`,
	`[a-z`,
	`([a-z)`,
	`[a-z)`,
	`([a-z]))`,
	`x{1001}`,
	`x{9876543210}`,
	`x{2,1}`,
	`x{1,9876543210}`,
	"\xff", // Invalid UTF-8
	"[\xff]",
	"[\\\xff]",
	"\\\xff",
	`(?P<name>a`,
	`(?P<name>`,
	`(?P<name`,
	`(?P<x y>a)`,
	`(?P<>a)`,
	`(?<name>a`,
	`(?<name>`,
	`(?<name`,
	`(?<x y>a)`,
	`(?<>a)`,
	`[a-Z]`,
	`(?i)[a-Z]`,
	`\Q\E*`,
	`a{100000}`,  // too much repetition
	`a{100000,}`, // too much repetition
	"((((((((((x{2}){2}){2}){2}){2}){2}){2}){2}){2}){2})",    // too much repetition
	strings.Repeat("(", 1000) + strings.Repeat(")", 1000),    // too deep
	strings.Repeat("(?:", 1000) + strings.Repeat(")*", 1000), // too deep
	"(" + strings.Repeat("(xx?)", 1000) + "){1000}",          // too long
	strings.Repeat("(xx?){1000}", 1000),                      // too long
}

// Copied from Go 1.27.1 src/regexp/syntax/parse_test.go (onlyPerl).
var onlyPerl = []string{
	`[a-b-c]`,
	`\Qabc\E`,
	`\Q*+?{[\E`,
	`\Q\\E`,
	`\Q\\\E`,
	`\Q\\\\E`,
	`\Q\\\\\E`,
	`(?:a)`,
	`(?P<name>a)`,
}

// Copied from Go 1.27.1 src/regexp/syntax/parse_test.go (onlyPOSIX).
var onlyPOSIX = []string{
	"a++",
	"a**",
	"a?*",
	"a+*",
	"a{1}*",
	".{1}{2}.{3}",
}

// Copied from Go 1.27.1 src/regexp/all_test.go (badRe), minus the 81 KB
// rune-budget pattern.
var badRe = []string{`*`, `+`, `?`, `(abc`, `abc)`, `x[a-z`, `[z-a]`, `abc\`, `a**`, `a*+`, `\x`}

// parserInputs are run on every valid pattern of the parser lists.
var parserInputs = []string{"", "a", "aa", "abc", "x", "xxxx", "*+?{[", `\E`}

// rep is Python's s*n.
func rep(s string, n int) string { return strings.Repeat(s, n) }

// limitPatterns are the parser resource-limit boundaries (Go's checkLimits:
// rune budget, program size, nesting height, and factor's recursion), each
// just inside and just outside the limit. Accepted patterns can compile to
// millions of instructions, so they are run on the empty input only.
func limitPatterns() []string {
	var out []string
	for _, k := range []int{999, 1000} {
		out = append(out,
			rep(".", k)+"x|"+rep(".", k)+"y",
			"(?:"+rep("[ab]", k)+"x|"+rep("[ab]", k)+"y)",
			rep("(", k)+"a"+rep(")", k),
		)
	}
	out = append(out, rep("(?:", 1000)+"a"+rep(")", 1000))
	for _, k := range []int{3355, 3356} {
		out = append(out, "(?:"+rep("a", k)+"){1000}")
	}
	star := "(?:" + rep("a*", 150) + "){1000}"
	out = append(out, star, rep(star, 10))
	out = append(out, "(?:"+rep("a", 4000)+"){1000}", "(?:"+rep("a", 4000)+"){1000})")
	// ('(?:'*908+'\pL'+')'*908)*9 and its 909-level variant are 32 KB; they
	// stay in src/limitstest.zig.
	out = append(out, "(?:(?:a{100}){10}){1000}", "((((a{2}){2}){2}){2}){1000}")
	var single, prefixed []string
	for i := 0; i < 2000; i++ {
		r := string(rune(0x10000 + 2*i))
		single = append(single, r)
		prefixed = append(prefixed, "x"+r)
	}
	out = append(out, strings.Join(single, "|"), strings.Join(prefixed, "|"))
	return out
}

func main() {
	w := corpus.NewWriter()
	for _, p := range patterns {
		c := corpus.Compile(p, corpus.Perl)
		if c.Err != "" {
			w.Write(c.Case(""))
			continue
		}
		for _, in := range inputs {
			w.Write(c.Case(in))
		}
	}
	var parserLists []string
	parserLists = append(parserLists, invalidRegexps...)
	parserLists = append(parserLists, onlyPerl...)
	parserLists = append(parserLists, onlyPOSIX...)
	parserLists = append(parserLists, badRe...)
	for _, p := range parserLists {
		for _, mode := range []corpus.Mode{corpus.Perl, corpus.POSIX} {
			c := corpus.Compile(p, mode)
			if c.Err != "" {
				w.Write(c.Case(""))
				continue
			}
			for _, in := range parserInputs {
				w.Write(c.Case(in))
			}
		}
	}
	for _, p := range limitPatterns() {
		for _, mode := range []corpus.Mode{corpus.Perl, corpus.POSIX} {
			w.Write(corpus.Compile(p, mode).Case(""))
		}
		// POSIX has no (?:...); its nearest equivalent uses capturing groups.
		if q := strings.ReplaceAll(p, "(?:", "("); q != p {
			w.Write(corpus.Compile(q, corpus.POSIX).Case(""))
		}
	}
	w.Close()
}
