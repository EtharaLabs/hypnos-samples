let cmd = 'uniq'
[(try { 5 | %($cmd) } catch {|e| $e.msg }) ([1 1 2] | %($cmd))]
