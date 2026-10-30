def nu-highlight [--pre: string = "<"] { $"($pre)($in)>" }
tutor begin | ansi strip | parse -r '(<[a-z]+>)' | get capture0 | first 2
