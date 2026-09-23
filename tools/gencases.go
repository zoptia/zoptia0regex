package main

import (
	"bufio"
	"encoding/json"
	"os"
	"regexp"
	"regexp/syntax"
)

type Case struct {
	P   string `json:"p"`
	I   string `json:"i"`
	Err bool   `json:"err"`
	M   []int  `json:"m"`
	NI  int    `json:"ni,omitempty"` // Go's program length (see progLen)
}

// progLen is the instruction count of the program Go's regexp.Compile builds
// for p (syntax.Parse with Perl flags, Simplify, Compile). The port must
// produce the same AST shape, so its program has exactly this many
// instructions; the differential tests check it.
func progLen(p string) int {
	re, err := syntax.Parse(p, syntax.Perl)
	if err != nil {
		return 0
	}
	prog, err := syntax.Compile(re.Simplify())
	if err != nil {
		return 0
	}
	return len(prog.Inst)
}

func main() {
	patterns := []string{
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
	inputs := []string{
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

	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	enc := json.NewEncoder(w)
	for _, p := range patterns {
		re, err := regexp.Compile(p)
		if err != nil {
			// record error once with empty input
			enc.Encode(Case{P: p, I: "", Err: true, M: nil})
			continue
		}
		ni := progLen(p)
		for _, in := range inputs {
			m := re.FindStringSubmatchIndex(in)
			enc.Encode(Case{P: p, I: in, Err: false, M: m, NI: ni})
		}
	}
}
