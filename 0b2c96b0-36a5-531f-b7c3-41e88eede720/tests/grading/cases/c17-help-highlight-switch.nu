def nu-highlight [--reject-garbage] { if $reject_garbage { $in } else { $"<<($in)>>" } }
@example "double two" { dbl 2 } --result 4
def dbl [x: int] { $x * 2 }
$env.config.use_ansi_coloring = true; help dbl | ansi strip | str contains "<<dbl 2>>"
