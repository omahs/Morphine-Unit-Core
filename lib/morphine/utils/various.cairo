from starkware.cairo.common.math import split_felt, unsigned_div_rem
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import uint256_unsigned_div_rem, uint256_mul
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.cairo_builtins import HashBuiltin

/// @title: Various
/// @author: Graff Sacha (0xSacha)
/// @dev: this contract is like a bagppack you can put all constant you needed inside
/// @custom: experimental This is an experimental contract.

// SELECTORS 
const APPROVE_SELECTOR = 949021990203918389843157787496164629863144228991510976554585288817234167820;
const REVERT_IF_RECEIVED_LESS_THAN_SELECTOR = 1152808638417114049948843928103925621792822987696523837861797894375176919641;
const ADD_COLLATERAL_SELECTOR = 1025283342371120815538937514731770015119272649696965755326343233655936090398;
const INCREASE_DEBT_SELECTOR = 3323238411793484043928226556773398225765836251146188154584443789205768679;
const DECREASE_DEBT_SELECTOR = 1034771968349403915231450891053234486965240191910712234547789345776861895252;
const ENABLE_TOKEN_SELECTOR = 338952900569808126805706745526330590233421914036538487636232796761524989536;
const DISABLE_TOKEN_SELECTOR = 47218719298910248124758889060083301755996642434054113693866970123813707233;
const DEPOSIT_ALL_SELECTOR = 396903410237766637967888614311112387181466559653238275327258099512853139542;
const DEPOSIT_SELECTOR = 352040181584456735608515580760888541466059565068553383579463728554843487745;
const REDEEM_SELECTOR = 1326975239452520649139862114866922847703907595552193666703522601892858398217;
const REDEEM_ALL_SELECTOR = 423968680392183900452876634644317800405150683283104824257728593535102065000;

// UTILS
const PRECISION = 1*10**18;
const SECONDS_PER_YEAR = 31536000;
const ALL_ONES = 2 ** 128 - 1;

// DEFAULTS
const DEFAULT_FEE_INTEREST = 1*10**17;
const DEFAULT_LIQUIDATION_PREMIUM = 4*10**16;
const DEFAULT_FEE_LIQUIDATION = 2*10**16;
const DEFAULT_FEE_LIQUIDATION_EXPIRED_PREMIUM = 4*10**16;
const DEFAULT_FEE_LIQUIDATION_EXPIRED = 2*10**16;

// MAX

// const MAX_WITHDRAW_FEE = ;
const DEFAULT_LIMIT_PER_BLOCK_MULTIPLIER = 5;

// AMMM
const MAX_PATH_LEN = 5;


// @notice: Uint256 to permillion in order to have better precision
// @param: x is a Uint256 (Uint256)
// @param: permillion is here to help to us have a better precision
// @return: New Uint256 with more precision
func uint256_permillion{pedersen_ptr: HashBuiltin*, range_check_ptr}(
    x: Uint256, permillion: Uint256
) -> (res: Uint256) {
    let (mul, _high) = uint256_mul(x, permillion);
    let (res, _) = uint256_unsigned_div_rem(mul, Uint256(PRECISION, 0));
    return (res=res);
}
