let cmd = 'reverse'
let extra = [3]
try { [1 2] | %($cmd) ...$extra } catch {|e| $e.msg }
