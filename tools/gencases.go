package main

import (
	"bufio"
	"encoding/json"
	"os"
	"regexp"
)

type Case struct {
	P   string `json:"p"`
	I   string `json:"i"`
	Err bool   `json:"err"`
	M   []int  `json:"m"`
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
		// unicode classes (supported subset)
		"\\pL+", "\\p{Greek}+", "\\p{Latin}+", "\\PL+", "\\p{Nd}+",
		"[\\p{L}\\d]+", "\\p{Han}+",
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
		for _, in := range inputs {
			m := re.FindStringSubmatchIndex(in)
			enc.Encode(Case{P: p, I: in, Err: false, M: m})
		}
	}
}
