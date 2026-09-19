// Public, unauthenticated network observations only. Never infer account access.
const countries=' AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW ';
function valid(c) { return type(c)=='string' && length(c)==2 && index(countries,' '+c+' ')>=0; }
export function classify(provider,body,code,rc) {
    let out={state:'unknown',country:null,http_code:code,transport:rc==0?'ok':'error',source:provider=='chatgpt'?'chatgpt_edge':'gemini_page'};
    if (rc!=0) { out.reason=rc==28?'timeout':rc==63?'response_too_large':'network_error'; return out; }
    if(code!=200) { out.reason=code==403 || code==429?'blocked_or_challenge':'http_response'; return out; }
    let country=null;
    if(provider=='chatgpt') {
        let loc=[],host=[];
        for(let line in split(body,'\n')) {
            let l=trim(line);
            if(match(l,/^loc=/)) push(loc,substr(l,4));
            if(match(l,/^h=/)) push(host,substr(l,2));
        }
        if(length(loc)==1 && length(host)==1 && host[0]=='chatgpt.com' && valid(loc[0])) country=loc[0];
    } else if(provider=='gemini') {
        // This is a page-internal field, not a documented stable Google API.
        // Parse only this exact JSON string; language/currency/other country text are not evidence.
        let field=match(body,/"vXmutd"\s*:\s*("(\\.|[^"\\])*")/);
        if(field) {
            try {
                let region=match(json(field[1]),/^%\.@\."([A-Z]{2})",/);
                if(region && valid(region[1])) country=region[1];
            } catch(e) {}
        }
    }
    out.country=country;
    out.state=country ? (country=='CN'?'cn':'non_cn') : 'unknown';
    out.reason=country?'country_observed':'country_missing';
    return out;
};
