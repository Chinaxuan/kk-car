'use strict';
import { sample } from '/etc/kk-car/ups-read.uc';

return { 'kkups': {
    status: { call:function() { return sample(); } }
}};
