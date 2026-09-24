'use strict';
// Only a uniquely identified domestic/general package may anchor estimates.
// Never infer a balance from a directional or multiple ambiguous packages.
function bytes(number,unit) {
    let n=+number;
    if (!(n>=0) || n>1000000) return null;
    let multiplier=unit=='GB' ? 1073741824 : unit=='MB' ? 1048576 : unit=='KB' ? 1024 : null;
    return multiplier==null ? null : int(n*multiplier);
}
function parse_balance(body,operator) {
    if (type(body)!='string' || length(body)>12000) return null;
    let lines=split(replace(body,/\r/g,''),'\n'), candidates=[];
    for (let line in lines) {
        let marker=operator=='CT' ? /国内上网可使用流量/ : /国内通用流量/;
        if (!match(line,marker)) continue;
        let used=match(line,/本月已使用\s*([0-9]+\.?[0-9]*)\s*(GB|MB|KB)/i);
        let left=match(line,/剩余\s*([0-9]+\.?[0-9]*)\s*(GB|MB|KB)/i);
        if (!used || !left) continue;
        let used_bytes=bytes(used[1],uc(used[2])), remaining_bytes=bytes(left[1],uc(left[2]));
        if (used_bytes==null || remaining_bytes==null) continue;
        push(candidates,{package:operator=='CT'?'国内上网通用流量':'国内通用流量',used_bytes,remaining_bytes});
    }
    return length(candidates)==1 ? candidates[0] : null;
}
export { parse_balance };
