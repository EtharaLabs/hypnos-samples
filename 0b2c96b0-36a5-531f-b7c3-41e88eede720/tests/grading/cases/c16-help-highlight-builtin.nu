def nu-highlight [] { $"<<($in)>>" }
$env.config.use_ansi_coloring = true; help str length | ansi strip | str contains "<<'hello' | str length>>"
