def table [--expand (-e), --collapse (-c), --width (-w): int] { let i = $in; if ($i | describe) == "string" { $i } else { $"TBL[(if $expand {'e'} else {''})(if $collapse {'c'} else {''})(if $width != null {'w'} else {''})]" } }
@example "plain" { dbl 2 } --result 4
@example "collapsed" { dbl 2 --collapse } --result 4
def dbl [x: int, --collapse] { $x * 2 }
help dbl | ansi strip | parse -r '(TBL\[[a-z]*\])' | get capture0
