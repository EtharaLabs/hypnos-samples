def nu-highlight [] { $"<<($in)>>" }
tutor begin | ansi strip | parse -r '(<<[^>]*>>)' | get capture0 | first 3
